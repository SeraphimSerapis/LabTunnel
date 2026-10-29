import Foundation
import XCTest
@testable import LabTunnel

// Socket helpers live outside the XCTestCase so `bind`/`listen` resolve to the C functions.
private func makeListener() -> (fd: Int32, port: Int) {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")  // port 0: kernel picks one
    let size = socklen_t(MemoryLayout<sockaddr_in>.size)
    withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = bind(fd, $0, size) } }
    listen(fd, 4)
    var len = size
    withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = getsockname(fd, $0, &len) } }
    return (fd, Int(UInt16(bigEndian: addr.sin_port)))
}

/// Accepts one connection on `listener` and hands it to `behavior`.
private func serveOnce(_ listener: Int32, _ behavior: @escaping (Int32) -> Void) {
    DispatchQueue.global().async {
        let client = accept(listener, nil, nil)
        if client >= 0 { behavior(client) }
    }
}

final class TunnelTests: XCTestCase {
    func testSSHArgumentsForwardLocalToRemoteLoopback() {
        let tunnel = Tunnel(name: "Grafana", host: "homelab", remotePort: 3000, localPort: 4000)
        let args = tunnel.sshArguments(localPort: 4001)
        XCTAssertEqual(args[args.firstIndex(of: "-L")! + 1], "127.0.0.1:4001:127.0.0.1:3000")
        XCTAssertTrue(args.contains("BatchMode=yes"))
        XCTAssertTrue(args.contains("ControlPath=none"))
        XCTAssertEqual(Array(args.suffix(2)), ["--", "homelab"])
    }

    func testValidationAcceptsGoodInput() {
        XCTAssertNil(Tunnel.validate(name: "A", host: "user@box", remotePort: 80, localPort: 8080))
        XCTAssertNil(Tunnel.validate(name: "A", host: "box", remotePort: 65535, localPort: 1))
    }

    func testValidationRejectsBadInput() {
        XCTAssertNotNil(Tunnel.validate(name: " ", host: "box", remotePort: 80, localPort: 80))
        XCTAssertNotNil(Tunnel.validate(name: "A", host: "", remotePort: 80, localPort: 80))
        XCTAssertNotNil(Tunnel.validate(name: "A", host: "-oProxyCommand=x", remotePort: 80, localPort: 80))
        XCTAssertNotNil(Tunnel.validate(name: "A", host: "a b", remotePort: 80, localPort: 80))
        XCTAssertNotNil(Tunnel.validate(name: "A", host: "box", remotePort: 0, localPort: 80))
        XCTAssertNotNil(Tunnel.validate(name: "A", host: "box", remotePort: 80, localPort: 65536))
        XCTAssertNotNil(Tunnel.validate(name: "A", host: "box", remotePort: nil, localPort: 80))
    }

    // MARK: Model

    func testURLFollowsSchemeAndTCPHasNone() {
        var tunnel = Tunnel(name: "A", host: "box", remotePort: 80, localPort: 80)
        XCTAssertEqual(tunnel.url(localPort: 8080)?.absoluteString, "http://127.0.0.1:8080")
        tunnel.scheme = .https
        XCTAssertEqual(tunnel.url(localPort: 8443)?.absoluteString, "https://127.0.0.1:8443")
        tunnel.scheme = .tcp
        XCTAssertNil(tunnel.url(localPort: 5432))
    }

    func testRouteHasNoThousandsSeparatorInAnyLocale() {
        let tunnel = Tunnel(name: "A", host: "prometheus", remotePort: 5173, localPort: 5173)
        XCTAssertEqual(tunnel.route(localPort: 5173), "prometheus:5173 → localhost:5173")
        XCTAssertEqual(tunnel.route(localPort: 65000), "prometheus:5173 → localhost:65000")
    }

    func testDecodesEntriesSavedBeforeNewFieldsExisted() throws {
        let json = """
        {"id":"11111111-1111-1111-1111-111111111111","name":"Old","host":"box","remotePort":80,"localPort":80}
        """
        let tunnel = try JSONDecoder().decode(Tunnel.self, from: Data(json.utf8))
        XCTAssertEqual(tunnel.scheme, .http)
        XCTAssertEqual(tunnel.group, "")
        XCTAssertFalse(tunnel.connectOnLaunch)
        XCTAssertFalse(tunnel.useFreePortIfBusy)
    }

    func testRoundTripKeepsNewFields() throws {
        let tunnel = Tunnel(name: "PG", host: "box", remotePort: 5432, localPort: 5432, scheme: .tcp,
                            group: "DB", connectOnLaunch: true, useFreePortIfBusy: true)
        let decoded = try JSONDecoder().decode(Tunnel.self, from: JSONEncoder().encode(tunnel))
        XCTAssertEqual(decoded, tunnel)
    }

    func testCosmeticEditsDoNotCountAsConnectionChange() {
        let base = Tunnel(name: "A", host: "box", remotePort: 80, localPort: 80)
        var renamed = base
        renamed.name = "B"; renamed.group = "G"; renamed.scheme = .https; renamed.connectOnLaunch = true
        XCTAssertTrue(base.sameConnection(as: renamed))
        var moved = base
        moved.remotePort = 81
        XCTAssertFalse(base.sameConnection(as: moved))
    }

    // MARK: Ports

    func testPortInUseDetection() {
        let (fd, port) = makeListener()
        XCTAssertTrue(isLocalPortInUse(port))
        close(fd)
        XCTAssertFalse(isLocalPortInUse(port))
    }

    func testPortIsFreeAgainWhileOldConnectionsLingerInTimeWait() {
        let (listener, port) = makeListener()
        // The server side closes first, which parks the 127.0.0.1:<port> endpoint in TIME_WAIT.
        let client = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port)).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(client, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        XCTAssertEqual(connected, 0)
        let accepted = accept(listener, nil, nil)
        close(accepted)
        usleep(100_000)
        close(client)
        close(listener)
        usleep(100_000)

        XCTAssertFalse(isLocalPortInUse(port))
    }

    func testFirstFreePortSkipsBusyAndReservedPorts() {
        let (fd, port) = makeListener()
        defer { close(fd) }
        let free = firstFreePort(from: port)
        XCTAssertNotNil(free)
        XCTAssertNotEqual(free, port)
        XCTAssertNotEqual(firstFreePort(from: port, skipping: [port + 1]), port + 1)
        XCTAssertNil(firstFreePort(from: 70000))
    }

    func testProbeReportsClosedWhenForwardDropsConnection() {
        let (fd, port) = makeListener()
        defer { close(fd) }
        serveOnce(fd) { close($0) }  // what ssh does when the remote port refuses
        XCTAssertEqual(probeRemoteListening(localPort: port, timeoutMs: 500), false)
    }

    func testProbeReportsListeningWhenConnectionStaysSilent() {
        let (fd, port) = makeListener()
        defer { close(fd) }
        serveOnce(fd) { client in sleep(2); close(client) }
        XCTAssertEqual(probeRemoteListening(localPort: port, timeoutMs: 300), true)
    }

    func testProbeReportsListeningWhenServerSpeaksFirst() {
        let (fd, port) = makeListener()
        defer { close(fd) }
        serveOnce(fd) { client in var byte: UInt8 = 65; send(client, &byte, 1, 0); sleep(2); close(client) }
        XCTAssertEqual(probeRemoteListening(localPort: port, timeoutMs: 500), true)
    }

    func testProbeIsUnknownWhenNothingListensLocally() {
        let (fd, port) = makeListener()
        close(fd)
        XCTAssertNil(probeRemoteListening(localPort: port, timeoutMs: 200))
    }

    // MARK: SSH config

    func testHostsParsingSkipsWildcardsAndNegations() {
        let config = """
        # a comment
        Host *
          ServerAliveInterval 30
        Host olympus tower 192.168.10.23
          User tim
        host=lowercase
        Host *.example.com !secret web?
        Host "quoted"
        Match host foo
          User x
        """
        XCTAssertEqual(SSHConfig.hosts(in: config), ["olympus", "tower", "192.168.10.23", "lowercase", "quoted"])
    }

    func testIncludePatternsAreCollected() {
        XCTAssertEqual(SSHConfig.includePatterns(in: "Include conf.d/*\n  include ~/other\nHost a"),
                       ["conf.d/*", "~/other"])
    }

    func testLoadHostsFollowsIncludesRelativeToSSHDir() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("lt-home-\(UUID())")
        let ssh = home.appendingPathComponent(".ssh")
        try FileManager.default.createDirectory(at: ssh.appendingPathComponent("conf.d"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try "Include conf.d/*\nHost Zeta\nHost alpha\n".write(to: ssh.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        try "Host beta alpha\n".write(to: ssh.appendingPathComponent("conf.d/extra.conf"), atomically: true, encoding: .utf8)

        XCTAssertEqual(SSHConfig.loadHosts(home: home), ["alpha", "beta", "Zeta"])
    }

    func testLoadHostsWithoutConfigIsEmpty() {
        XCTAssertEqual(SSHConfig.loadHosts(home: FileManager.default.temporaryDirectory.appendingPathComponent("nope-\(UUID())")), [])
    }

    // MARK: Traffic

    func testNettopRowParsing() {
        XCTAssertEqual(TrafficMonitor.parse("ssh.36789,390,870,")?.up, 390)
        XCTAssertEqual(TrafficMonitor.parse("ssh.36789,390,870,")?.down, 870)
        XCTAssertNil(TrafficMonitor.parse(",bytes_in,bytes_out,"))
        XCTAssertNil(TrafficMonitor.parse("curl.1234,5,6,"))
        XCTAssertNil(TrafficMonitor.parse("ssh.1,abc,6,"))
        XCTAssertNil(TrafficMonitor.parse(""))
    }

    func testCounterComputesRatesFromCumulativeSamples() {
        var counter = TrafficCounter()
        let t0 = Date()
        counter.sample(up: 0, down: 0, at: t0)
        counter.sample(up: 1000, down: 4000, at: t0.addingTimeInterval(2))
        XCTAssertEqual(counter.current, Traffic(up: 1000, down: 4000, upRate: 500, downRate: 2000))
        counter.sample(up: 1000, down: 4000, at: t0.addingTimeInterval(3))
        XCTAssertEqual(counter.current.upRate, 0)
        XCTAssertEqual(counter.current.down, 4000)
    }

    func testCounterKeepsTotalsAcrossSSHRestarts() {
        var counter = TrafficCounter()
        let t0 = Date()
        counter.sample(up: 100, down: 200, at: t0)
        counter.endSession()
        XCTAssertEqual(counter.current.up, 100)
        XCTAssertEqual(counter.current.downRate, 0)
        // A new ssh process starts its own counters from zero.
        counter.sample(up: 0, down: 0, at: t0.addingTimeInterval(5))
        counter.sample(up: 30, down: 70, at: t0.addingTimeInterval(6))
        XCTAssertEqual(counter.current.up, 130)
        XCTAssertEqual(counter.current.down, 270)
    }

    func testCounterNeverReportsNegativeRate() {
        var counter = TrafficCounter()
        let t0 = Date()
        counter.sample(up: 500, down: 500, at: t0)
        counter.sample(up: 100, down: 100, at: t0.addingTimeInterval(1))
        XCTAssertEqual(counter.current.upRate, 0)
    }

    func testSmallByteCountsUseCompactUnit() {
        XCTAssertEqual(TrafficFormat.bytes(0), "0 B")
        XCTAssertEqual(TrafficFormat.bytes(870), "870 B")
        XCTAssertEqual(TrafficFormat.summary(Traffic(up: 390, down: 870)), "↑ 390 B  ↓ 870 B")
        XCTAssertFalse(TrafficFormat.bytes(5 * 1024 * 1024).contains("B "), "larger values come from ByteCountFormatter")
    }

    func testSummaryShowsRateOnlyWhileDataFlows() {
        XCTAssertTrue(TrafficFormat.summary(Traffic(up: 2048, down: 5 * 1024 * 1024, upRate: 0, downRate: 1024)).contains("/s"))
        XCTAssertFalse(TrafficFormat.summary(Traffic(up: 2048, down: 4096)).contains("/s"))
    }

    // MARK: Process output

    func testOutputTailDrainsAChattyProcessAndKeepsOnlyTheEnd() throws {
        // ~180 KB of stderr, well past the 64 KB a pipe holds. Read only at exit, the child
        // blocks on a full pipe and never exits, which is how chatty ssh tunnels used to hang.
        let tail = OutputTail(limit: 1024)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", """
            i=0; while [ $i -lt 3000 ]; do
              echo "channel $i: open failed: connect failed: Connection refused" >&2; i=$((i+1))
            done; echo "last line" >&2
            """]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = tail.pipe
        let exited = expectation(description: "process exits")
        var output = ""
        process.terminationHandler = { _ in
            output = tail.text()
            exited.fulfill()
        }
        try process.run()
        wait(for: [exited], timeout: 10)

        XCTAssertTrue(output.hasSuffix("last line\n"), "the final line, which carries ssh's error, survives")
        XCTAssertLessThanOrEqual(output.utf8.count, 1024)
    }

    func testOutputTailReturnsEverythingWhenShort() throws {
        let tail = OutputTail()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "echo 'Permission denied (publickey).' >&2; exit 255"]
        process.standardError = tail.pipe
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(tail.text(), "Permission denied (publickey).\n")
    }

    // MARK: Watchdog

    private func spawnSleeper() throws -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sleep")
        p.arguments = ["30"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        addTeardownBlock { p.terminate() }
        return p
    }

    private func waitForExit(_ process: Process, seconds: Double = 2) {
        let deadline = Date().addingTimeInterval(seconds)
        while process.isRunning && Date() < deadline { usleep(10_000) }
    }

    func testWatchdogFiresWhileAnotherChildHoldsNoCopyOfTheLifeline() throws {
        let victim = try spawnSleeper()
        let watchdog = try Watchdog(killing: [victim.processIdentifier])
        // Started after the watchdog. If it inherited the pipe's write end, the watchdog's read
        // would not return until this process exited too.
        let bystander = try spawnSleeper()
        usleep(100_000)

        watchdog.simulateAppExit()
        waitForExit(victim)
        XCTAssertFalse(victim.isRunning)
        XCTAssertTrue(bystander.isRunning)
    }

    func testStoppedWatchdogSparesItsTargets() throws {
        let victim = try spawnSleeper()
        let watchdog = try Watchdog(killing: [victim.processIdentifier])
        usleep(100_000)
        watchdog.stop()
        watchdog.waitUntilExit()
        watchdog.simulateAppExit()
        usleep(300_000)
        XCTAssertTrue(victim.isRunning)
    }

    // MARK: PID registry

    func testReapSparesUnrelatedSSHSessionsAndKillsOurTunnels() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pids-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }

        // Both hang in the proxy command instead of touching the network.
        func spawnSSH(_ extra: [String]) throws -> Process {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            p.arguments = extra + ["-o", "ProxyCommand=exec sleep 30", "-o", "BatchMode=yes", "example.invalid"]
            // Detach from the test runner's pipes, or the lingering `sleep` keeps `swift test` waiting.
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            p.standardInput = FileHandle.nullDevice
            try p.run()
            return p
        }
        let unrelated = try spawnSSH([])  // a user's own ssh whose PID we "remember"
        let ours = try spawnSSH(["-N", "-o", "ControlPath=none", "-L", "127.0.0.1:22999:127.0.0.1:22"])
        defer { unrelated.terminate(); ours.terminate() }
        usleep(300_000)

        let registry = PIDRegistry(url: url)
        registry.add(unrelated.processIdentifier)
        registry.add(ours.processIdentifier)
        registry.reapOrphans()

        ours.waitUntilExit()
        XCTAssertFalse(ours.isRunning)
        XCTAssertTrue(unrelated.isRunning)
    }

    func testReapOrphansForgetsEverythingAndIgnoresNonSSHProcesses() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pids-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let registry = PIDRegistry(url: url)
        // Our own PID is a test runner, not /usr/bin/ssh, so it must survive the reap.
        registry.add(getpid())
        registry.reapOrphans()
        XCTAssertEqual(try JSONDecoder().decode([Int32].self, from: Data(contentsOf: url)), [])
        XCTAssertTrue(PIDRegistry.executablePath(of: getpid()) != "/usr/bin/ssh")
    }
}

@MainActor
final class ManagerTests: XCTestCase {
    func testSectionsListUngroupedFirstThenGroupsAlphabetically() {
        let store = FileManager.default.temporaryDirectory.appendingPathComponent("lt-\(UUID())/tunnels.json")
        let manager = TunnelManager(storeURL: store)
        manager.save(Tunnel(name: "1", host: "a", remotePort: 1, localPort: 1, group: "media"))
        manager.save(Tunnel(name: "2", host: "a", remotePort: 2, localPort: 2))
        manager.save(Tunnel(name: "3", host: "a", remotePort: 3, localPort: 3, group: "Dev"))
        manager.save(Tunnel(name: "4", host: "a", remotePort: 4, localPort: 4, group: "media"))

        XCTAssertEqual(manager.sections.map(\.name), ["", "Dev", "media"])
        XCTAssertEqual(manager.sections[2].tunnels.map(\.name), ["1", "4"])
        XCTAssertEqual(manager.knownGroups, ["Dev", "media"])
    }

    private func makeLiveManager() throws -> TunnelManager {
        let manager = TunnelManager(storeURL: temporaryStoreURL(), sshExecutable: try makeFakeSSH())
        addTeardownBlock { @MainActor in manager.disconnectAll() }
        return manager
    }

    func testSavingNewPortsReconnectsALiveTunnel() throws {
        let manager = try makeLiveManager()
        let tunnel = Tunnel(name: "web", host: "box", remotePort: 80, localPort: freeLocalPort())
        manager.save(tunnel)
        manager.connect(tunnel)
        XCTAssertEqual(manager.state(of: tunnel), .connecting)

        var moved = tunnel
        moved.localPort = freeLocalPort()
        manager.save(moved)
        XCTAssertEqual(manager.state(of: moved), .connecting, "the edit in the menu keeps the tunnel on")
        XCTAssertEqual(manager.localPort(of: moved), moved.localPort)
    }

    func testSavingNewPortsLeavesAnIdleTunnelOff() {
        let manager = TunnelManager(storeURL: temporaryStoreURL())
        var tunnel = Tunnel(name: "web", host: "box", remotePort: 80, localPort: 8080)
        manager.save(tunnel)
        tunnel.localPort = 8081
        manager.save(tunnel)
        XCTAssertEqual(manager.state(of: tunnel), .idle)
    }

    func testNamesAreUniqueIgnoringCaseAndWhitespace() {
        let manager = TunnelManager(storeURL: temporaryStoreURL())
        let web = Tunnel(name: "Grafana", host: "box", remotePort: 3000, localPort: 3000)
        manager.save(web)
        XCTAssertTrue(manager.isNameTaken(" grafana ", except: nil))
        XCTAssertFalse(manager.isNameTaken("GRAFANA", except: web.id), "a tunnel may keep its own name")
        XCTAssertFalse(manager.isNameTaken("Prometheus", except: nil))
    }
}
