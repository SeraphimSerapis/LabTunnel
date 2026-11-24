import AppKit
import Darwin
import Network
import Observation

/// Owns the saved tunnels and the `ssh` processes behind them.
@MainActor
@Observable
final class TunnelManager {
    private(set) var tunnels: [Tunnel] = [] {
        didSet { notifyWaiters() }
    }
    private(set) var states: [UUID: TunnelState] = [:] {
        didSet { notifyWaiters() }
    }
    /// The port each active tunnel really listens on. Differs from `Tunnel.localPort`
    /// when the preferred port was busy and the entry allows a fallback.
    private(set) var localPorts: [UUID: Int] = [:]
    private(set) var remoteStatus: [UUID: RemoteStatus] = [:] {
        didSet { notifyWaiters() }
    }
    private(set) var traffic: [UUID: Traffic] = [:]
    private(set) var connectedSince: [UUID: Date] = [:]

    @ObservationIgnored private var processes: [UUID: Process] = [:]
    @ObservationIgnored private var outputTails: [UUID: OutputTail] = [:]
    @ObservationIgnored private var waitTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var watchdog: Watchdog?
    @ObservationIgnored private var trackedWatchdogPIDs: Set<Int32> = []
    @ObservationIgnored private var trafficMonitor: TrafficMonitor?
    @ObservationIgnored private var trafficMonitorID: UUID?
    @ObservationIgnored private var pidToTunnel: [Int32: UUID] = [:]
    @ObservationIgnored private var monitorRestartTask: Task<Void, Never>?
    @ObservationIgnored private var counters: [UUID: TrafficCounter] = [:]
    /// Tunnels in auto-reconnect mode: they were up once, so failures are retried, not reported.
    @ObservationIgnored private var retrying: Set<UUID> = []
    @ObservationIgnored private var attempts: [UUID: Int] = [:]
    @ObservationIgnored private var retryTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var waiters: [UUID: @MainActor @Sendable () -> Void] = [:]
    @ObservationIgnored private let storeURL: URL
    @ObservationIgnored private let sshExecutable: URL
    @ObservationIgnored private let pidRegistry: PIDRegistry
    @ObservationIgnored private let probeQueue = DispatchQueue(
        label: "dev.messerschmidt.labtunnel.probe",
        attributes: .concurrent
    )
    @ObservationIgnored private let networkQueue = DispatchQueue(label: "dev.messerschmidt.labtunnel.network")
    @ObservationIgnored private nonisolated(unsafe) var wakeObserver: NSObjectProtocol?
    @ObservationIgnored private nonisolated(unsafe) var pathMonitor: NWPathMonitor?
    @ObservationIgnored private nonisolated(unsafe) var pathDebounceWork: DispatchWorkItem?
    @ObservationIgnored private var lastPathStatus: NWPath.Status?
    @ObservationIgnored private var lastInterfaceType: NWInterface.InterfaceType?

    /// `sshExecutable` exists for tests, which substitute a stand-in that never connects.
    init(storeURL: URL = TunnelManager.defaultStoreURL,
         sshExecutable: URL = URL(fileURLWithPath: "/usr/bin/ssh"),
         monitorNetwork: Bool? = nil) {
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
        let shouldMonitorNetwork = monitorNetwork ?? (sshExecutable.path == "/usr/bin/ssh")
        if shouldMonitorNetwork {
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { [weak self] path in
                guard let self else { return }
                self.pathDebounceWork?.cancel()
                let item = DispatchWorkItem { [weak self] in
                    Task { @MainActor [weak self] in
                        self?.handleNetworkPathChange(path)
                    }
                }
                self.pathDebounceWork = item
                self.networkQueue.asyncAfter(deadline: .now() + .milliseconds(500), execute: item)
            }
            monitor.start(queue: networkQueue)
            pathMonitor = monitor
        }
    }

    deinit {
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        pathDebounceWork?.cancel()
        pathMonitor?.cancel()
    }

    nonisolated static var defaultStoreURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LabTunnel/tunnels.json")
    }

    var connectedCount: Int { tunnels.filter { state(of: $0) == .connected }.count }
    var activeCount: Int { tunnels.filter { state(of: $0).isActive }.count }
    var reconnectingCount: Int { tunnels.filter { state(of: $0) == .reconnecting }.count }
    var failedCount: Int {
        tunnels.filter {
            if case .failed = state(of: $0) { return true }
            return false
        }.count
    }
    var knownHosts: [String] { Array(Set(tunnels.map(\.host))).sorted() }

    var knownGroups: [String] {
        var firstCasing: [String: String] = [:]
        for tunnel in tunnels where !tunnel.group.isEmpty {
            let key = tunnel.group.lowercased()
            if firstCasing[key] == nil {
                firstCasing[key] = tunnel.group
            }
        }
        return firstCasing.values.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Ungrouped entries first, then one section per group in alphabetical order.
    var sections: [TunnelSection] {
        var result: [TunnelSection] = []
        let ungrouped = tunnels.filter { $0.group.isEmpty }
        if !ungrouped.isEmpty { result.append(TunnelSection(name: "", tunnels: ungrouped)) }
        var grouped: [String: [Tunnel]] = [:]
        for tunnel in tunnels where !tunnel.group.isEmpty {
            grouped[tunnel.group.lowercased(), default: []].append(tunnel)
        }
        for group in knownGroups {
            result.append(TunnelSection(name: group, tunnels: grouped[group.lowercased()] ?? []))
        }
        return result
    }

    func state(of tunnel: Tunnel) -> TunnelState { states[tunnel.id] ?? .idle }
    func localPort(of tunnel: Tunnel) -> Int { localPorts[tunnel.id] ?? tunnel.localPort }
    func remoteStatus(of tunnel: Tunnel) -> RemoteStatus { remoteStatus[tunnel.id] ?? .unknown }

    func uptimeSeconds(of tunnel: Tunnel) -> Int? {
        guard state(of: tunnel) == .connected, let since = connectedSince[tunnel.id] else { return nil }
        return max(0, Int(Date().timeIntervalSince(since)))
    }

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
        connectedSince[tunnel.id] = nil
        persist()
    }

    // MARK: Connecting

    func toggle(_ tunnel: Tunnel) {
        state(of: tunnel).isActive ? disconnect(tunnel) : connect(tunnel)
    }

    /// Switches every entry in `group` on or off.
    func setGroup(_ group: String, connected: Bool) {
        for tunnel in tunnels where tunnel.group.caseInsensitiveCompare(group) == .orderedSame {
            let active = state(of: tunnel).isActive
            if connected && !active { connect(tunnel) }
            if !connected && active { disconnect(tunnel) }
        }
    }

    func connectOnLaunchTunnels() {
        tunnels.filter(\.connectOnLaunch).forEach(connect)
    }

    func connectAll() {
        for tunnel in tunnels where !state(of: tunnel).isActive {
            connect(tunnel)
        }
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
        waitTasks.removeValue(forKey: id)?.cancel()
        // Close stderr tail before terminating so intentional disconnects do not wait 2s on stderr.
        outputTails.removeValue(forKey: id)?.close()
        // Drop the process first so its termination handler knows this was deliberate.
        if let process = processes.removeValue(forKey: id) {
            let pid = process.processIdentifier
            pidRegistry.remove(pid)
            untrackWatchdog(pid: pid)
            process.terminate()
        }
        stopTrafficMonitoring(id: id)
        counters[id] = nil
        traffic[id] = nil
        states[id] = .idle
        localPorts[id] = nil
        remoteStatus[id] = nil
        connectedSince[id] = nil
    }

    /// Called on app quit. Waits briefly so the local ports are free again afterwards.
    func disconnectAll() {
        waitTasks.values.forEach { $0.cancel() }
        waitTasks.removeAll()
        retryTasks.values.forEach { $0.cancel() }
        retryTasks.removeAll()
        retrying.removeAll()
        attempts.removeAll()
        monitorRestartTask?.cancel()
        monitorRestartTask = nil

        trafficMonitor?.stop()
        trafficMonitor = nil
        trafficMonitorID = nil
        pidToTunnel.removeAll()

        // Stop the watchdog first. Once our process exits it would otherwise fire at PIDs
        // that already belong to nothing, or to something else.
        trackedWatchdogPIDs.removeAll()
        watchdog?.stop()
        watchdog = nil

        outputTails.values.forEach { $0.close() }
        outputTails.removeAll()

        let running = Array(processes.values)
        processes.removeAll()
        running.forEach {
            if $0.isRunning { $0.terminate() }
        }
        let deadline = Date().addingTimeInterval(2.0)
        while running.contains(where: \.isRunning) && Date() < deadline {
            usleep(20_000)
        }
        for process in running where process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }

        pidRegistry.clear()
        counters.removeAll()
        traffic.removeAll()
        for id in states.keys { states[id] = .idle }
        localPorts.removeAll()
        remoteStatus.removeAll()
        connectedSince.removeAll()
    }

    /// Re-runs the "is anything listening on the remote side" check for a connected tunnel.
    func recheckRemote(_ tunnel: Tunnel) {
        let id = tunnel.id
        guard states[id] == .connected, let port = localPorts[id], let process = processes[id] else { return }
        remoteStatus[id] = .unknown
        let queue = probeQueue
        Task { [weak self] in
            let result = await withCheckedContinuation { continuation in
                queue.async {
                    continuation.resume(returning: probeRemoteListening(localPort: port))
                }
            }
            guard let self, self.processes[id] === process, self.states[id] == .connected else { return }
            switch result {
            case true?: self.remoteStatus[id] = .listening
            case false?: self.remoteStatus[id] = .notListening
            case nil: self.remoteStatus[id] = .unknown
            }
        }
    }

    /// Waits until every tunnel in `ids` settles into connected, failed, or idle (or is removed),
    /// and any connected tunnel finishes its initial remote check (up to 4s after settling).
    /// Returns `true` only if `timeout` expires while a tunnel is still connecting or reconnecting.
    func waitForSettlement(ids: [UUID], timeout: TimeInterval) async -> Bool {
        let clock = ContinuousClock()
        let overallDeadline = clock.now + .seconds(max(0, timeout))
        var settledAt: ContinuousClock.Instant?

        while true {
            let (settled, remoteDone) = settlementStatus(for: ids)
            if settled {
                if remoteDone { return false }
                if settledAt == nil { settledAt = clock.now }
                if let settledAt, clock.now >= settledAt + .seconds(4) { return false }
            } else {
                settledAt = nil
            }

            if clock.now >= overallDeadline || Task.isCancelled {
                return !settled
            }

            let nextDeadline = settledAt.map { min(overallDeadline, $0 + .seconds(4)) } ?? overallDeadline
            await waitForStateChange(until: nextDeadline, clock: clock)
        }
    }

    private func settlementStatus(for ids: [UUID]) -> (settled: Bool, remoteDone: Bool) {
        var allSettled = true
        var allRemoteDone = true
        for id in ids {
            guard tunnels.contains(where: { $0.id == id }) else { continue }
            let currentState = states[id] ?? .idle
            switch currentState {
            case .connected:
                if (remoteStatus[id] ?? .unknown) == .unknown {
                    allRemoteDone = false
                }
            case .idle, .failed:
                break
            case .connecting, .reconnecting:
                allSettled = false
            }
        }
        return (allSettled, allRemoteDone)
    }

    private func waitForStateChange(until deadline: ContinuousClock.Instant, clock: ContinuousClock) async {
        let waiterID = UUID()
        let box = WaiterBox()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                waiters[waiterID] = { [weak self] in
                    self?.waiters.removeValue(forKey: waiterID)
                    box.wake()
                }
                let sleepTask = Task { @MainActor [weak self] in
                    try? await clock.sleep(until: deadline, tolerance: nil)
                    self?.waiters.removeValue(forKey: waiterID)
                    box.wake()
                }
                if !box.arm(continuation: continuation, sleepTask: sleepTask) {
                    waiters.removeValue(forKey: waiterID)
                    sleepTask.cancel()
                    continuation.resume()
                }
            }
        } onCancel: {
            box.wake()
            Task { @MainActor [weak self] in
                self?.waiters.removeValue(forKey: waiterID)
            }
        }
    }

    private func notifyWaiters() {
        guard !waiters.isEmpty else { return }
        let current = Array(waiters.values)
        waiters.removeAll()
        current.forEach { $0() }
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
        let stderr = OutputTail { [weak self, weak process] line in
            guard line.contains("open failed: connect failed:") else { return }
            Task { @MainActor in
                guard let self,
                      let process,
                      self.processes[id] === process,
                      self.states[id] == .connected else { return }
                if self.remoteStatus[id] != .notListening {
                    self.remoteStatus[id] = .notListening
                }
            }
        }
        process.executableURL = sshExecutable
        process.arguments = tunnel.sshArguments(localPort: port)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderr.pipe
        process.terminationHandler = { [weak self] proc in
            let output = stderr.text()
            Task { @MainActor in self?.processExited(proc, id: id, stderr: output) }
        }

        do {
            try process.run()
        } catch {
            stderr.close()
            fail(tunnel, error.localizedDescription)
            return
        }
        let pid = process.processIdentifier
        pidRegistry.add(pid)
        trackWatchdog(pid: pid)
        outputTails[id] = stderr
        processes[id] = process
        localPorts[id] = port
        states[id] = retrying.contains(id) ? .reconnecting : .connecting
        remoteStatus[id] = nil
        connectedSince[id] = nil

        waitTasks[id]?.cancel()
        waitTasks[id] = Task { [weak self] in
            await self?.waitUntilListening(tunnel, port: port, process: process)
        }
    }

    // MARK: Shared watchdog and traffic monitor

    private func trackWatchdog(pid: Int32) {
        guard pid > 0 else { return }
        trackedWatchdogPIDs.insert(pid)
        if watchdog == nil || watchdog?.isRunning == false {
            watchdog?.stop()
            do {
                let wd = try Watchdog()
                watchdog = wd
                for activePID in trackedWatchdogPIDs {
                    wd.track(activePID)
                }
            } catch {
                watchdog = nil
                NSLog("LabTunnel: could not start watchdog: \(error)")
            }
        } else {
            watchdog?.track(pid)
        }
    }

    private func untrackWatchdog(pid: Int32) {
        guard pid > 0, trackedWatchdogPIDs.remove(pid) != nil else { return }
        watchdog?.untrack(pid)
        if trackedWatchdogPIDs.isEmpty {
            watchdog?.stop()
            watchdog = nil
        }
    }

    private func startTrafficMonitoring(id: UUID, pid: Int32) {
        monitorRestartTask?.cancel()
        monitorRestartTask = nil
        pidToTunnel[pid] = id
        var counter = counters[id] ?? TrafficCounter()
        counter.sample(up: 0, down: 0, monotonicSeconds: ProcessInfo.processInfo.systemUptime)
        counters[id] = counter
        if traffic[id] != counter.current {
            traffic[id] = counter.current
        }
        ensureTrafficMonitorRunning()
        trafficMonitor?.track(pid: pid)
    }

    private func ensureTrafficMonitorRunning() {
        guard !pidToTunnel.isEmpty, trafficMonitor == nil else { return }
        let monitorID = UUID()
        guard let monitor = TrafficMonitor(
            onSamples: { [weak self] batch in
                let now = ProcessInfo.processInfo.systemUptime
                Task { @MainActor in
                    self?.handleTrafficSamples(batch, monotonicSeconds: now)
                }
            },
            onUnexpectedExit: { [weak self] in
                Task { @MainActor in
                    self?.handleTrafficMonitorExit(id: monitorID)
                }
            }
        ) else { return }
        trafficMonitor = monitor
        trafficMonitorID = monitorID
        trackWatchdog(pid: monitor.processIdentifier)
        for pid in pidToTunnel.keys {
            monitor.track(pid: pid)
        }
    }

    private func stopTrafficMonitoring(id: UUID) {
        let removedPIDs = pidToTunnel.compactMap { $0.value == id ? $0.key : nil }
        for pid in removedPIDs {
            pidToTunnel.removeValue(forKey: pid)
            trafficMonitor?.untrack(pid: pid)
        }
        counters[id]?.endSession()
        if let next = counters[id]?.current, traffic[id] != next {
            traffic[id] = next
        }
        if pidToTunnel.isEmpty {
            monitorRestartTask?.cancel()
            monitorRestartTask = nil
            if let monitor = trafficMonitor {
                trafficMonitor = nil
                trafficMonitorID = nil
                untrackWatchdog(pid: monitor.processIdentifier)
                monitor.stop()
            }
        }
    }

    private func handleTrafficSamples(_ batch: [Int32: (up: Int, down: Int)], monotonicSeconds: TimeInterval) {
        guard trafficMonitor != nil else { return }
        for (pid, sample) in batch {
            guard let id = pidToTunnel[pid] else { continue }
            let previousDown = counters[id]?.current.down ?? 0
            var counter = counters[id] ?? TrafficCounter()
            counter.sample(up: sample.up, down: sample.down, monotonicSeconds: monotonicSeconds)
            counters[id] = counter
            let next = counter.current
            if traffic[id] != next {
                traffic[id] = next
            }
            if remoteStatus[id] == .notListening && next.down > previousDown {
                remoteStatus[id] = .listening
            }
        }
    }

    private func handleTrafficMonitorExit(id exitedID: UUID) {
        guard trafficMonitorID == exitedID, let exited = trafficMonitor else { return }
        trafficMonitor = nil
        trafficMonitorID = nil
        untrackWatchdog(pid: exited.processIdentifier)
        guard !pidToTunnel.isEmpty else { return }
        for id in Set(pidToTunnel.values) {
            counters[id]?.endSession()
            if let next = counters[id]?.current, traffic[id] != next {
                traffic[id] = next
            }
        }
        monitorRestartTask?.cancel()
        monitorRestartTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            self.monitorRestartTask = nil
            guard !self.pidToTunnel.isEmpty else { return }
            self.ensureTrafficMonitorRunning()
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
        let pid = process.processIdentifier
        let initialDelaysMs = [25, 50, 100, 150]
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(12)
        var step = 0

        while true {
            guard !Task.isCancelled, processes[tunnel.id] === process else { return }
            if isProcessListening(pid: pid, port: port) {
                waitTasks[tunnel.id] = nil
                states[tunnel.id] = .connected
                connectedSince[tunnel.id] = Date()
                retrying.remove(tunnel.id)
                attempts[tunnel.id] = nil
                startTrafficMonitoring(id: tunnel.id, pid: pid)
                recheckRemote(tunnel)
                return
            }
            if clock.now >= deadline { break }
            let delayMs = step < initialDelaysMs.count ? initialDelaysMs[step] : 200
            step += 1
            try? await Task.sleep(for: .milliseconds(delayMs))
        }

        guard !Task.isCancelled, processes[tunnel.id] === process else { return }
        waitTasks[tunnel.id] = nil
        if retrying.contains(tunnel.id) {
            process.terminate()  // processExited schedules the next retry
        } else {
            disconnect(tunnel)
            states[tunnel.id] = .failed("Timed out waiting for the tunnel.")
        }
    }

    private func processExited(_ process: Process, id: UUID, stderr: String) {
        let pid = process.processIdentifier
        pidRegistry.remove(pid)
        untrackWatchdog(pid: pid)
        // Ignore exits we caused ourselves via disconnect().
        guard processes[id] === process else { return }
        processes[id] = nil
        waitTasks.removeValue(forKey: id)?.cancel()
        outputTails.removeValue(forKey: id)?.close()
        connectedSince[id] = nil
        remoteStatus[id] = nil
        stopTrafficMonitoring(id: id)  // totals stay, so a reconnect keeps counting from where it left off
        if states[id] == .connected { retrying.insert(id) }

        let message = OutputTail.extractError(from: stderr) ?? "Connection closed."
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
    /// Kill them now and wake any sleeping retries immediately.
    private func restartAfterWake() {
        restartAfterNetworkRecovery()
    }

    private func handleNetworkPathChange(_ path: NWPath) {
        let newStatus = path.status
        let newInterface = path.availableInterfaces.first?.type
        defer {
            lastPathStatus = newStatus
            lastInterfaceType = newInterface
        }
        guard let previousStatus = lastPathStatus else { return }

        if previousStatus != .satisfied && newStatus == .satisfied {
            restartAfterNetworkRecovery()
        } else if previousStatus == .satisfied && newStatus == .satisfied && newInterface != lastInterfaceType {
            wakeSleepingReconnects()
            for tunnel in tunnels where state(of: tunnel) == .connected {
                recheckRemote(tunnel)
            }
        }
    }

    private func restartAfterNetworkRecovery() {
        for (id, process) in processes where states[id]?.isActive == true {
            retrying.insert(id)
            process.terminate()
        }
        wakeSleepingReconnects()
    }

    private func wakeSleepingReconnects() {
        let sleepingIDs = Array(retryTasks.keys)
        for id in sleepingIDs {
            retryTasks.removeValue(forKey: id)?.cancel()
            attempts[id] = 0
            if let current = tunnels.first(where: { $0.id == id }), processes[id] == nil {
                start(current)
            }
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

private final class WaiterBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var sleepTask: Task<Void, Never>?
    private var woken = false

    func arm(continuation: CheckedContinuation<Void, Never>, sleepTask: Task<Void, Never>) -> Bool {
        lock.withLock {
            if woken { return false }
            self.continuation = continuation
            self.sleepTask = sleepTask
            return true
        }
    }

    func wake() {
        let (cont, task) = lock.withLock { () -> (CheckedContinuation<Void, Never>?, Task<Void, Never>?) in
            if woken { return (nil, nil) }
            woken = true
            let c = continuation
            let t = sleepTask
            continuation = nil
            sleepTask = nil
            return (c, t)
        }
        task?.cancel()
        cont?.resume()
    }
}
