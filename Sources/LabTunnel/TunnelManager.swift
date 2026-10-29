import AppKit
import Observation

/// Owns the saved tunnels and the `ssh` processes behind them.
@MainActor
@Observable
final class TunnelManager {
    private(set) var tunnels: [Tunnel] = []
    private(set) var states: [UUID: TunnelState] = [:]
    /// The port each active tunnel really listens on. Differs from `Tunnel.localPort`
    /// when the preferred port was busy and the entry allows a fallback.
    private(set) var localPorts: [UUID: Int] = [:]
    private(set) var remoteStatus: [UUID: RemoteStatus] = [:]
    private(set) var traffic: [UUID: Traffic] = [:]

    @ObservationIgnored private var processes: [UUID: Process] = [:]
    @ObservationIgnored private var watchdogs: [UUID: Watchdog] = [:]
    @ObservationIgnored private var monitors: [UUID: TrafficMonitor] = [:]
    @ObservationIgnored private var counters: [UUID: TrafficCounter] = [:]
    /// Tunnels in auto-reconnect mode: they were up once, so failures are retried, not reported.
    @ObservationIgnored private var retrying: Set<UUID> = []
    @ObservationIgnored private var attempts: [UUID: Int] = [:]
    @ObservationIgnored private var retryTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private let storeURL: URL
    @ObservationIgnored private let sshExecutable: URL
    @ObservationIgnored private let pidRegistry: PIDRegistry
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?

    /// `sshExecutable` exists for tests, which substitute a stand-in that never connects.
    init(storeURL: URL = TunnelManager.defaultStoreURL,
         sshExecutable: URL = URL(fileURLWithPath: "/usr/bin/ssh")) {
        self.storeURL = storeURL
        self.sshExecutable = sshExecutable
        pidRegistry = PIDRegistry(url: storeURL.deletingLastPathComponent().appendingPathComponent("ssh-pids.json"))
        load()
        pidRegistry.reapOrphans()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.restartAfterWake() }
        }
    }

    nonisolated static var defaultStoreURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LabTunnel/tunnels.json")
    }

    var connectedCount: Int { tunnels.filter { state(of: $0) == .connected }.count }
    var knownHosts: [String] { Array(Set(tunnels.map(\.host))).sorted() }
    var knownGroups: [String] {
        Array(Set(tunnels.map(\.group).filter { !$0.isEmpty }))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Ungrouped entries first, then one section per group in alphabetical order.
    var sections: [TunnelSection] {
        var result: [TunnelSection] = []
        let ungrouped = tunnels.filter { $0.group.isEmpty }
        if !ungrouped.isEmpty { result.append(TunnelSection(name: "", tunnels: ungrouped)) }
        for group in knownGroups {
            result.append(TunnelSection(name: group, tunnels: tunnels.filter { $0.group == group }))
        }
        return result
    }

    func state(of tunnel: Tunnel) -> TunnelState { states[tunnel.id] ?? .idle }
    func localPort(of tunnel: Tunnel) -> Int { localPorts[tunnel.id] ?? tunnel.localPort }
    func remoteStatus(of tunnel: Tunnel) -> RemoteStatus { remoteStatus[tunnel.id] ?? .unknown }

    // MARK: Editing

    /// Adds or replaces `tunnel`. A live tunnel whose host or ports changed reconnects with
    /// the new settings; renaming, regrouping or changing the type leaves it running.
    func save(_ tunnel: Tunnel) {
        guard let index = tunnels.firstIndex(where: { $0.id == tunnel.id }) else {
            tunnels.append(tunnel)
            persist()
            return
        }
        let old = tunnels[index]
        let restart = !old.sameConnection(as: tunnel)
        let wasActive = state(of: old).isActive
        if restart { disconnect(old) }
        tunnels[index] = tunnel
        persist()
        if restart && wasActive { connect(tunnel) }
    }

    /// Names are how the CLI and agents address tunnels, so they stay unique, ignoring case.
    func isNameTaken(_ name: String, except id: UUID?) -> Bool {
        let wanted = name.trimmingCharacters(in: .whitespaces)
        return tunnels.contains { $0.id != id && $0.name.caseInsensitiveCompare(wanted) == .orderedSame }
    }

    func delete(_ tunnel: Tunnel) {
        disconnect(tunnel)
        tunnels.removeAll { $0.id == tunnel.id }
        states[tunnel.id] = nil
        persist()
    }

    // MARK: Connecting

    func toggle(_ tunnel: Tunnel) {
        state(of: tunnel).isActive ? disconnect(tunnel) : connect(tunnel)
    }

    /// Switches every entry in `group` on or off.
    func setGroup(_ group: String, connected: Bool) {
        for tunnel in tunnels where tunnel.group == group {
            let active = state(of: tunnel).isActive
            if connected && !active { connect(tunnel) }
            if !connected && active { disconnect(tunnel) }
        }
    }

    func connectOnLaunchTunnels() {
        tunnels.filter(\.connectOnLaunch).forEach(connect)
    }

    /// User-initiated connect. Starts a fresh attempt: failures are reported, not retried,
    /// until the tunnel has been up once.
    func connect(_ tunnel: Tunnel) {
        guard processes[tunnel.id] == nil else { return }
        cancelRetry(tunnel.id)
        counters[tunnel.id] = nil
        traffic[tunnel.id] = nil
        start(tunnel)
    }

    func disconnect(_ tunnel: Tunnel) {
        let id = tunnel.id
        cancelRetry(id)
        watchdogs.removeValue(forKey: id)?.stop()
        // Drop the process first so its termination handler knows this was deliberate.
        if let process = processes.removeValue(forKey: id) {
            pidRegistry.remove(process.processIdentifier)
            process.terminate()
        }
        stopMonitor(id)
        counters[id] = nil
        traffic[id] = nil
        states[id] = .idle
        localPorts[id] = nil
        remoteStatus[id] = nil
    }

    /// Called on app quit. Waits briefly so the local ports are free again afterwards.
    func disconnectAll() {
        retryTasks.values.forEach { $0.cancel() }
        retryTasks.removeAll()
        retrying.removeAll()
        attempts.removeAll()
        // Stop the watchdogs first. Once our process exits they would otherwise fire at PIDs
        // that already belong to nothing, or to something else.
        let dogs = Array(watchdogs.values)
        watchdogs.removeAll()
        dogs.forEach { $0.stop() }
        dogs.forEach { $0.waitUntilExit() }
        let running = Array(processes.values)
        processes.removeAll()
        running.forEach { $0.terminate() }
        running.forEach { $0.waitUntilExit() }
        pidRegistry.clear()
        monitors.values.forEach { $0.stop() }
        monitors.removeAll()
        counters.removeAll()
        traffic.removeAll()
        for id in states.keys { states[id] = .idle }
        localPorts.removeAll()
        remoteStatus.removeAll()
    }

    /// Re-runs the "is anything listening on the remote side" check for a connected tunnel.
    func recheckRemote(_ tunnel: Tunnel) {
        let id = tunnel.id
        guard states[id] == .connected, let port = localPorts[id], let process = processes[id] else { return }
        remoteStatus[id] = .unknown
        Task {
            let result = await Task.detached { probeRemoteListening(localPort: port) }.value
            guard processes[id] === process, states[id] == .connected else { return }
            switch result {
            case true?: remoteStatus[id] = .listening
            case false?: remoteStatus[id] = .notListening
            case nil: remoteStatus[id] = .unknown
            }
        }
    }

    // MARK: Process lifecycle

    private func start(_ tunnel: Tunnel) {
        let id = tunnel.id
        guard processes[id] == nil else { return }
        guard let port = choosePort(for: tunnel) else {
            fail(tunnel, "Local port \(tunnel.localPort) is already in use.")
            return
        }

        let process = Process()
        process.executableURL = sshExecutable
        process.arguments = tunnel.sshArguments(localPort: port)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let stderr = OutputTail()
        process.standardError = stderr.pipe
        process.terminationHandler = { [weak self] proc in
            let output = stderr.text()
            Task { @MainActor in self?.processExited(proc, id: id, stderr: output) }
        }

        do {
            try process.run()
        } catch {
            fail(tunnel, error.localizedDescription)
            return
        }
        pidRegistry.add(process.processIdentifier)
        startMonitor(id: id, pid: process.processIdentifier)
        startWatchdog(id: id, pids: [process.processIdentifier] + (monitors[id].map { [$0.processIdentifier] } ?? []))
        processes[id] = process
        localPorts[id] = port
        states[id] = .connecting
        remoteStatus[id] = nil
        Task { await waitUntilListening(tunnel, port: port, process: process) }
    }

    private func startMonitor(id: UUID, pid: Int32) {
        stopMonitor(id)
        let generation = UUID()
        let monitor = TrafficMonitor(pid: pid, generation: generation) { [weak self] up, down in
            Task { @MainActor in self?.recordTraffic(id: id, generation: generation, up: up, down: down) }
        }
        guard let monitor else { return }  // traffic stats are optional; the tunnel still works
        monitors[id] = monitor
        counters[id, default: TrafficCounter()].sample(up: 0, down: 0)
    }

    private func stopMonitor(_ id: UUID) {
        monitors.removeValue(forKey: id)?.stop()
        counters[id]?.endSession()
        if let counter = counters[id] { traffic[id] = counter.current }
    }

    private func recordTraffic(id: UUID, generation: UUID, up: Int, down: Int) {
        // Ignore late samples from a monitor that has since been replaced or stopped.
        guard monitors[id]?.generation == generation else { return }
        counters[id, default: TrafficCounter()].sample(up: up, down: down)
        traffic[id] = counters[id]?.current
    }

    /// Kills the tunnel's `ssh` and traffic monitor if LabTunnel dies without cleaning up.
    private func startWatchdog(id: UUID, pids: [Int32]) {
        watchdogs.removeValue(forKey: id)?.stop()
        do {
            watchdogs[id] = try Watchdog(killing: pids)
        } catch {
            NSLog("LabTunnel: could not start watchdog: \(error)")
        }
    }

    /// The preferred local port if free, else the next free one when the entry allows it.
    /// Ports claimed by our other tunnels count as taken even before ssh has bound them.
    private func choosePort(for tunnel: Tunnel) -> Int? {
        let claimed = Set(processes.keys.filter { $0 != tunnel.id }.compactMap { localPorts[$0] })
        if !claimed.contains(tunnel.localPort) && !isLocalPortInUse(tunnel.localPort) { return tunnel.localPort }
        guard tunnel.useFreePortIfBusy else { return nil }
        return firstFreePort(from: tunnel.localPort + 1, skipping: claimed)
    }

    private func waitUntilListening(_ tunnel: Tunnel, port: Int, process: Process) async {
        // ConnectTimeout is 10s; allow a little more before giving up.
        for _ in 0..<60 {
            guard processes[tunnel.id] === process else { return }
            if isLocalPortInUse(port) {
                states[tunnel.id] = .connected
                retrying.remove(tunnel.id)
                attempts[tunnel.id] = nil
                recheckRemote(tunnel)
                return
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        guard processes[tunnel.id] === process else { return }
        if retrying.contains(tunnel.id) {
            process.terminate()  // processExited schedules the next retry
        } else {
            disconnect(tunnel)
            states[tunnel.id] = .failed("Timed out waiting for the tunnel.")
        }
    }

    private func processExited(_ process: Process, id: UUID, stderr: String) {
        pidRegistry.remove(process.processIdentifier)
        // Ignore exits we caused ourselves via disconnect().
        guard processes[id] === process else { return }
        processes[id] = nil
        watchdogs.removeValue(forKey: id)?.stop()
        remoteStatus[id] = nil
        stopMonitor(id)  // totals stay, so a reconnect keeps counting from where it left off
        if states[id] == .connected { retrying.insert(id) }

        let lastLine = stderr.split(whereSeparator: \.isNewline).last
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let message = (lastLine?.isEmpty == false ? lastLine : nil) ?? "Connection closed."
        if let tunnel = tunnels.first(where: { $0.id == id }) {
            fail(tunnel, message)
        }
    }

    /// Reports a failure, or schedules a retry if the tunnel is in auto-reconnect mode.
    private func fail(_ tunnel: Tunnel, _ message: String) {
        let id = tunnel.id
        guard retrying.contains(id) else {
            states[id] = .failed(message)
            localPorts[id] = nil
            return
        }
        let attempt = (attempts[id] ?? 0) + 1
        attempts[id] = attempt
        states[id] = .reconnecting
        // 1s, 2s, 4s, 8s, 16s, then every 30s.
        let delay = min(30, 1 << min(attempt - 1, 5))
        retryTasks[id]?.cancel()
        retryTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.retryTasks[id] = nil
            guard self.states[id] == .reconnecting,
                  let current = self.tunnels.first(where: { $0.id == id }) else { return }
            self.start(current)
        }
    }

    private func cancelRetry(_ id: UUID) {
        retrying.remove(id)
        attempts[id] = nil
        retryTasks.removeValue(forKey: id)?.cancel()
    }

    /// After sleep the old SSH sessions are usually dead but won't notice for ~45s.
    /// Kill them now and let the reconnect path rebuild them.
    private func restartAfterWake() {
        for (id, process) in processes where states[id]?.isActive == true {
            retrying.insert(id)
            process.terminate()
        }
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let saved = try? JSONDecoder().decode([Tunnel].self, from: data) else { return }
        tunnels = saved
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(
                at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(tunnels).write(to: storeURL, options: .atomic)
        } catch {
            NSLog("LabTunnel: could not save tunnels: \(error)")
        }
    }
}
