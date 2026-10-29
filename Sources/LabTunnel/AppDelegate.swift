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

/// Owns the menu bar item and popover, and tears every tunnel down on quit, including quits
/// triggered by SIGTERM/SIGINT.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var manager: TunnelManager!
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var signalSources: [DispatchSourceSignal] = []
    private var controlServer: ControlServer?
    private var outsideClickMonitor: Any?
    private var escapeMonitor: Any?
    /// While the editor is showing, Esc belongs to its Cancel button, not to the popover.
    private var isEditing = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Two copies share ssh-pids.json, so a second one would reap the first one's live ssh
        // processes on launch and then compete with it for local ports. Step aside instead.
        // This also covers a dev build started with `swift run` while the installed app runs.
        if ControlClient().isRunning() {
            NSLog("LabTunnel: another instance is already running; exiting.")
            NSApp.terminate(nil)
            return
        }

        manager = TunnelManager()

        let hosting = NSHostingController(rootView: MenuContent(
            manager: manager,
            onEditingChange: { [weak self] in self?.isEditing = $0 }
        ))
        // Let the popover follow the SwiftUI content size in both directions.
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        // `.transient` closes the popover the moment the app activates, which raced with
        // `show` and made it flash and vanish. Dismissal is explicit instead; see showPopover.
        popover.behavior = .applicationDefined
        popover.delegate = self

        // Cmd-Tab or clicking into another app deactivates us. Close then, but only if we
        // are still inactive after a moment, so a transient activation flip doesn't dismiss it.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400))
                if let self, self.popover.isShown, !NSApp.isActive { self.popover.performClose(nil) }
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
        controlServer?.stop()
        manager?.disconnectAll()  // nil when a second instance exited before setting up
    }

    @objc private func togglePopover() {
        popover.isShown ? popover.performClose(nil) : showPopover()
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)

        // Clicks in other apps never reach us, so watch for them globally. Clicks on our own
        // status item go through togglePopover instead. Mouse monitors need no permission.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in self?.popover.performClose(nil) }
        }

        // Esc closes the list view. A key monitor is needed because the popover window itself
        // is the first responder, so `cancelOperation` never reaches our controller.
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, let self, !self.isEditing else { return event }
            self.popover.performClose(nil)
            return nil
        }

        // Activate on the next turn of the run loop, after `show` has finished. An accessory app
        // isn't active by default, and without this the text fields wouldn't take focus.
        DispatchQueue.main.async { [popover] in
            NSApp.activate(ignoringOtherApps: true)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func popoverDidClose(_ notification: Notification) {
        for monitor in [outsideClickMonitor, escapeMonitor] {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
        outsideClickMonitor = nil
        escapeMonitor = nil
    }

    /// Redraws the icon and live-tunnel count whenever the observed state changes.
    private func trackStatusIcon() {
        let count = withObservationTracking {
            manager.connectedCount
        } onChange: { [weak self] in
            Task { @MainActor in self?.trackStatusIcon() }
        }
        guard let button = statusItem.button else { return }
        let symbol = count > 0
            ? "point.3.filled.connected.trianglepath.dotted"
            : "point.3.connected.trianglepath.dotted"
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "LabTunnel")
        button.title = count > 0 ? " \(count)" : ""
    }
}
