import AppKit
import Observation
import SwiftUI
import LabTunnelControl

/// Plain AppKit entry point. A SwiftUI `App` needs a scene, and the only one that fits (an
/// empty `Settings`) opens a blank window on launch. The UI is an NSStatusItem + NSPopover
/// instead of `MenuBarExtra`, whose window grows with its content but never shrinks again,
/// which left a tall, empty window under the menu bar after closing the editor.
@main
enum LabTunnelMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()  // never returns, so `delegate` stays alive
    }
}

@MainActor
@Observable
final class PopoverModel {
    var openCount = 0
}

/// Owns the menu bar item and popover, and tears every tunnel down on quit, including quits
/// triggered by SIGTERM/SIGINT.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var manager: TunnelManager!
    private var statusItem: NSStatusItem!
    private var popover: NSPopover?
    private let popoverModel = PopoverModel()
    private var instanceLock: InstanceLock?
    private var signalSources: [DispatchSourceSignal] = []
    private var controlServer: ControlServer?
    private var resignObserver: NSObjectProtocol?
    private var outsideClickMonitor: Any?
    private var escapeMonitor: Any?
    /// While the editor is showing or a search query is active, Esc is handled by SwiftUI.
    private var isEditing = false

    private let idleIcon: NSImage? = {
        let image = NSImage(systemSymbolName: "point.3.connected.trianglepath.dotted", accessibilityDescription: "LabTunnel")
        image?.isTemplate = true
        return image
    }()

    private let connectedIcon: NSImage? = {
        let image = NSImage(systemSymbolName: "point.3.filled.connected.trianglepath.dotted", accessibilityDescription: "LabTunnel")
        image?.isTemplate = true
        return image
    }()

    private var lastConnectedCount: Int?
    private var lastNeedsAttention: Bool?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Two copies share ssh-pids.json, so a second one would reap the first one's live ssh
        // processes on launch and then compete with it for local ports. Step aside instead.
        // Acquire the advisory lock first before touching TunnelManager or the control socket.
        instanceLock = InstanceLock.acquire(at: ControlPaths.defaultLockURL)
        if instanceLock == nil || ControlClient().isRunning() {
            instanceLock?.release()
            instanceLock = nil
            NSLog("LabTunnel: another instance is already running; exiting.")
            NSApp.terminate(nil)
            return
        }

        manager = TunnelManager()

        // Cmd-Tab or clicking into another app deactivates us. Close then, but only if we
        // are still inactive after a moment, so a transient activation flip doesn't dismiss it.
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.popover?.isShown == true else { return }
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(400))
                    if let self, self.popover?.isShown == true, !NSApp.isActive {
                        self.popover?.performClose(nil)
                    }
                }
            }
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover)
            button.imagePosition = .imageLeading
        }
        trackStatusIcon()

        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }

        manager.connectOnLaunchTunnels()

        let server = ControlServer(manager: manager)
        do {
            try server.start()
            controlServer = server
        } catch {
            NSLog("LabTunnel: control socket unavailable: \(error)")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
            self.resignObserver = nil
        }
        controlServer?.stop()
        manager?.disconnectAll()  // nil when a second instance exited before setting up
        instanceLock?.release()
        instanceLock = nil
    }

    @objc private func togglePopover() {
        if let popover, popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    private func ensurePopover() -> NSPopover {
        if let popover { return popover }
        let created = NSPopover()
        let hosting = NSHostingController(rootView: MenuContent(
            manager: manager,
            popoverModel: popoverModel,
            onEditingChange: { [weak self] in self?.isEditing = $0 }
        ))
        // Let the popover follow the SwiftUI content size in both directions.
        hosting.sizingOptions = [.preferredContentSize]
        created.contentViewController = hosting
        // `.transient` closes the popover the moment the app activates, which raced with
        // `show` and made it flash and vanish. Dismissal is explicit instead; see showPopover.
        created.behavior = .applicationDefined
        created.delegate = self
        popover = created
        return created
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        popoverModel.openCount += 1
        let popover = ensurePopover()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)

        removeEventMonitors()

        // Clicks in other apps never reach us, so watch for them globally. Clicks on our own
        // status item go through togglePopover instead. Mouse monitors need no permission.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in self?.popover?.performClose(nil) }
        }

        // Esc closes the list view. A key monitor is needed because the popover window itself
        // is the first responder, so `cancelOperation` never reaches our controller.
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, let self, !self.isEditing else { return event }
            self.popover?.performClose(nil)
            return nil
        }

        // Activate on the next turn of the run loop, after `show` has finished. An accessory app
        // isn't active by default, and without this the text fields wouldn't take focus.
        DispatchQueue.main.async { [weak popover] in
            NSApp.activate(ignoringOtherApps: true)
            popover?.contentViewController?.view.window?.makeKey()
        }
    }

    func popoverDidClose(_ notification: Notification) {
        removeEventMonitors()
    }

    private func removeEventMonitors() {
        for monitor in [outsideClickMonitor, escapeMonitor] {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
        outsideClickMonitor = nil
        escapeMonitor = nil
    }

    /// Redraws the icon and live-tunnel count whenever the observed state changes.
    private func trackStatusIcon() {
        let (count, needsAttention) = withObservationTracking {
            let count = manager.connectedCount
            let attention = manager.tunnels.contains { tunnel in
                if case .failed = manager.state(of: tunnel) { return true }
                return manager.state(of: tunnel) == .connected && manager.remoteStatus(of: tunnel) == .notListening
            }
            return (count, attention)
        } onChange: { [weak self] in
            Task { @MainActor in self?.trackStatusIcon() }
        }
        guard count != lastConnectedCount || needsAttention != lastNeedsAttention else { return }
        lastConnectedCount = count
        lastNeedsAttention = needsAttention

        guard let button = statusItem.button else { return }
        button.image = count > 0 ? connectedIcon : idleIcon
        button.title = count > 0 ? " \(count)" : ""
        button.toolTip = needsAttention ? "LabTunnel: attention needed" : "LabTunnel"
    }
}
