import Darwin
import Foundation
import XCTest
@testable import LabTunnel

private func makeIPv4Listener(address: String) -> (fd: Int32, port: Int) {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_addr.s_addr = inet_addr(address)
    let size = socklen_t(MemoryLayout<sockaddr_in>.size)
    withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = bind(fd, $0, size) } }
    listen(fd, 4)
    var len = size
    withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = getsockname(fd, $0, &len) } }
    return (fd, Int(UInt16(bigEndian: addr.sin_port)))
}

private func makeIPv6Listener(address: in6_addr) -> (fd: Int32, port: Int) {
    let fd = socket(AF_INET6, SOCK_STREAM, 0)
    var v6only: Int32 = 1
    setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &v6only, socklen_t(MemoryLayout<Int32>.size))
    var addr = sockaddr_in6()
    addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
    addr.sin6_family = sa_family_t(AF_INET6)
    addr.sin6_addr = address
    let size = socklen_t(MemoryLayout<sockaddr_in6>.size)
    withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = bind(fd, $0, size) } }
    listen(fd, 4)
    var len = size
    withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = getsockname(fd, $0, &len) } }
    return (fd, Int(UInt16(bigEndian: addr.sin6_port)))
}

private final class LineBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []

    func append(_ line: String) {
        lock.withLock { items.append(line) }
    }

    func snapshot() -> [String] {
        lock.withLock { items }
    }
}

final class EngineTests: XCTestCase {
    private func spawnSleeper() throws -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sleep")
        p.arguments = ["30"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        try p.run()
        addTeardownBlock { if p.isRunning { p.terminate() } }
        return p
    }

    private func waitUntil(_ condition: () -> Bool, seconds: Double = 2.0) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            usleep(10_000)
        }
        return condition()
    }

    // MARK: Watchdog

    func testSharedWatchdogTracksUntracksAndKillsRemainingOnCrash() throws {
        let victim = try spawnSleeper()
        let spared = try spawnSleeper()
        let watchdog = try Watchdog()
        defer { watchdog.stop() }

        watchdog.track(victim.processIdentifier)
        watchdog.track(victim.processIdentifier) // duplicate track is safe
        watchdog.track(spared.processIdentifier)
        watchdog.untrack(spared.processIdentifier)
        let bystander = try spawnSleeper()
        usleep(100_000)

        watchdog.simulateAppExit()
        XCTAssertTrue(waitUntil { !victim.isRunning })
        XCTAssertFalse(victim.isRunning)
        XCTAssertTrue(spared.isRunning)
        XCTAssertTrue(bystander.isRunning)
    }

    func testSharedWatchdogCleanStopSparesTrackedProcesses() throws {
        let victim = try spawnSleeper()
        let watchdog = try Watchdog(killing: [victim.processIdentifier])
        usleep(100_000)

        watchdog.stop()
        watchdog.waitUntilExit()
        XCTAssertFalse(watchdog.isRunning)

        // Calling stop() and simulateAppExit() repeatedly must be safe and spare targets.
        watchdog.stop()
        watchdog.simulateAppExit()
        usleep(200_000)
        XCTAssertTrue(victim.isRunning)
    }

    // MARK: Traffic

    func testTrafficMonitorParseHandlesGeneralNamesAndRejectsInvalidRows() {
        let ssh = TrafficMonitor.parse("ssh.36789,390,870,")
        XCTAssertEqual(ssh?.pid, 36789)
        XCTAssertEqual(ssh?.up, 390)
        XCTAssertEqual(ssh?.down, 870)

        let dotted = TrafficMonitor.parse("io.tailscale.ip.13965,12,34,")
        XCTAssertEqual(dotted?.pid, 13965)
        XCTAssertEqual(dotted?.up, 12)
        XCTAssertEqual(dotted?.down, 34)

        let spaced = TrafficMonitor.parse("Google Chrome.2880,100,200,")
        XCTAssertEqual(spaced?.pid, 2880)
        XCTAssertEqual(spaced?.up, 100)
        XCTAssertEqual(spaced?.down, 200)

        XCTAssertNil(TrafficMonitor.parse(",bytes_in,bytes_out,"))
        XCTAssertNil(TrafficMonitor.parse(".123,5,6,"))
        XCTAssertNil(TrafficMonitor.parse("ssh.abc,5,6,"))
        XCTAssertNil(TrafficMonitor.parse("ssh.1,abc,6,"))
        XCTAssertNil(TrafficMonitor.parse("ssh.1,5,abc,"))
        XCTAssertNil(TrafficMonitor.parse(""))
    }

    func testMonotonicTrafficCounterComputesRatesAndCarriesAcrossRestarts() {
        var counter = TrafficCounter()
        counter.sample(up: 0, down: 0, monotonicSeconds: 10.0)
        counter.sample(up: 1000, down: 4000, monotonicSeconds: 12.0)
        XCTAssertEqual(counter.current, Traffic(up: 1000, down: 4000, upRate: 500, downRate: 2000))

        counter.endSession()
        XCTAssertEqual(counter.current.upRate, 0)
        XCTAssertEqual(counter.current.downRate, 0)

        counter.sample(up: 50, down: 100, monotonicSeconds: 20.0)
        counter.sample(up: 150, down: 300, monotonicSeconds: 22.0)
        XCTAssertEqual(counter.current, Traffic(up: 1150, down: 4300, upRate: 50, downRate: 100))

        // Wall-clock overload continues to behave consistently.
        let t0 = Date()
        var wallCounter = TrafficCounter()
        wallCounter.sample(up: 100, down: 200, at: t0)
        wallCounter.sample(up: 300, down: 600, at: t0.addingTimeInterval(2))
        XCTAssertEqual(wallCounter.current, Traffic(up: 300, down: 600, upRate: 100, downRate: 200))
    }

    func testTrafficFormatBytesUsesBinaryCache() {
        XCTAssertEqual(TrafficFormat.bytes(512), "512 B")
        XCTAssertEqual(TrafficFormat.bytes(1024), ByteCountFormatter.string(fromByteCount: 1024, countStyle: .binary))
        XCTAssertEqual(TrafficFormat.bytes(5 * 1024 * 1024), ByteCountFormatter.string(fromByteCount: 5 * 1024 * 1024, countStyle: .binary))
    }

    // MARK: PIDRegistry

    func testPIDRegistryArgumentsAndIsLabTunnelSSH() throws {
        let currentArgs = PIDRegistry.arguments(of: getpid())
        XCTAssertNotNil(currentArgs)
        XCTAssertFalse(currentArgs?.isEmpty ?? true)
        XCTAssertEqual(PIDRegistry.commandLine(of: getpid()), currentArgs?.joined(separator: " "))
        XCTAssertNil(PIDRegistry.arguments(of: -1))

        func spawnSSH(_ extra: [String]) throws -> Process {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            p.arguments = extra + ["-o", "ProxyCommand=sleep 30", "-o", "BatchMode=yes", "example.invalid"]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            p.standardInput = FileHandle.nullDevice
            try p.run()
            addTeardownBlock { if p.isRunning { p.terminate() } }
            return p
        }

        let oursSplit = try spawnSSH(["-N", "-o", "ControlPath=none", "-L", "127.0.0.1:22998:127.0.0.1:22"])
        let oursJoined = try spawnSSH(["-N", "-o", "ControlPath=none", "-L127.0.0.1:22997:127.0.0.1:22"])
        let unrelated = try spawnSSH([])
        usleep(250_000)

        XCTAssertTrue(PIDRegistry.isLabTunnelSSH(oursSplit.processIdentifier))
        XCTAssertTrue(PIDRegistry.isLabTunnelSSH(oursJoined.processIdentifier))
        XCTAssertFalse(PIDRegistry.isLabTunnelSSH(unrelated.processIdentifier))
        XCTAssertFalse(PIDRegistry.isLabTunnelSSH(getpid()))
    }

    func testPIDRegistryDeduplicatesAndSkipsMissingFileOnReap() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lt-reg-\(UUID())")
        let url = dir.appendingPathComponent("ssh-pids.json")
        defer { try? FileManager.default.removeItem(at: dir) }

        let registry = PIDRegistry(url: url)
        registry.reapOrphans()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        registry.add(getpid())
        registry.add(getpid())
        let stored = try JSONDecoder().decode([Int32].self, from: Data(contentsOf: url))
        XCTAssertEqual(stored, [getpid()])
    }

    // MARK: Ports

    func testIsLocalPortInUseDetectsAllBindFamiliesAndRejectsInvalidPorts() {
        XCTAssertFalse(isLocalPortInUse(0))
        XCTAssertFalse(isLocalPortInUse(-1))
        XCTAssertFalse(isLocalPortInUse(65536))
        XCTAssertFalse(isProcessListening(pid: getpid(), port: 0))
        XCTAssertNil(probeRemoteListening(localPort: 0))
        XCTAssertNil(probeRemoteListening(localPort: 70000))

        let v4Loop = makeIPv4Listener(address: "127.0.0.1")
        XCTAssertTrue(isLocalPortInUse(v4Loop.port))
        close(v4Loop.fd)

        let v4Any = makeIPv4Listener(address: "0.0.0.0")
        XCTAssertTrue(isLocalPortInUse(v4Any.port))
        close(v4Any.fd)

        let v6Loop = makeIPv6Listener(address: in6addr_loopback)
        XCTAssertTrue(isLocalPortInUse(v6Loop.port))
        close(v6Loop.fd)

        let v6Any = makeIPv6Listener(address: in6addr_any)
        XCTAssertTrue(isLocalPortInUse(v6Any.port))
        close(v6Any.fd)
    }

    func testIsProcessListeningMatchesOwnSocketAndRejectsWrongPort() {
        let listener = makeIPv4Listener(address: "127.0.0.1")
        defer { close(listener.fd) }

        XCTAssertTrue(isProcessListening(pid: getpid(), port: listener.port))
        let otherPort = firstFreePort(from: listener.port + 1) ?? (listener.port == 65535 ? 65534 : listener.port + 1)
        XCTAssertFalse(isProcessListening(pid: getpid(), port: otherPort))
        XCTAssertFalse(isProcessListening(pid: -1, port: listener.port))
    }

    // MARK: OutputTail

    func testOutputTailOnLineTrimmingAndTimeoutCleanup() throws {
        let lineBox = LineBox()
        let tail = OutputTail(limit: 12) { line in
            lineBox.append(line)
        }

        let writer = tail.pipe.fileHandleForWriting
        try writer.write(contentsOf: Data("first\r\nsecond\n123456789012".utf8))
        usleep(50_000)
        XCTAssertEqual(lineBox.snapshot(), ["first", "second"])

        // Timeout closes readabilityHandler cleanly without leaking, even while writer is still open.
        let timedOutText = tail.text(waitingUpTo: .milliseconds(50))
        XCTAssertEqual(timedOutText, "123456789012")
        XCTAssertNil(tail.pipe.fileHandleForReading.readabilityHandler)
        try? writer.close()
    }

    func testExtractErrorSkipsBannersAndPrefersSpecificCause() {
        let hostKeyStderr = """
        @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
        @    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @
        @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
        Host key verification failed.
        """
        XCTAssertEqual(OutputTail.extractError(from: hostKeyStderr), "Host key verification failed.")

        let genericAfterRefused = """
        channel_setup_fwd_listener_tcpip: cannot listen to port: 8080: Address already in use
        Could not request local forwarding.
        """
        XCTAssertEqual(
            OutputTail.extractError(from: genericAfterRefused),
            "channel_setup_fwd_listener_tcpip: cannot listen to port: 8080: Address already in use"
        )

        let onlyBanners = "@@@@@@@@@@\n   \r\n"
        XCTAssertNil(OutputTail.extractError(from: onlyBanners))
    }

    // MARK: SSHConfig

    func testSSHConfigQuotesEqualsCyclesAndCachedReload() throws {
        let parsed = SSHConfig.includePatterns(in: """
        Include "conf dir/*.conf" extra=part.conf
        Host "my host" app=prod
        """)
        XCTAssertEqual(parsed, ["conf dir/*.conf", "extra=part.conf"])
        XCTAssertEqual(SSHConfig.hosts(in: "Host \"my host\" app=prod\n"), ["my host", "app=prod"])

        let home = FileManager.default.temporaryDirectory.appendingPathComponent("lt-ssh-\(UUID())")
        let sshDir = home.appendingPathComponent(".ssh")
        let confDir = sshDir.appendingPathComponent("conf dir")
        try FileManager.default.createDirectory(at: confDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let configURL = sshDir.appendingPathComponent("config")
        try "Include \"conf dir/*.conf\"\nHost alpha\n".write(to: configURL, atomically: true, encoding: .utf8)
        try "Include \"~/.ssh/conf dir/../conf dir/one=1.conf\"\nHost beta\n".write(
            to: confDir.appendingPathComponent("one=1.conf"), atomically: true, encoding: .utf8
        )

        XCTAssertEqual(SSHConfig.loadHostsCached(home: home), ["alpha", "beta"])
        // Adding a new file in included dir invalidates cache via directory mtime.
        usleep(10_000)
        try "Host gamma\n".write(to: confDir.appendingPathComponent("two.conf"), atomically: true, encoding: .utf8)
        XCTAssertEqual(SSHConfig.loadHostsCached(home: home), ["alpha", "beta", "gamma"])

        // Updating main config invalidates cache via file mtime.
        usleep(10_000)
        try "Include \"conf dir/*.conf\"\nHost alpha\nHost delta\n".write(to: configURL, atomically: true, encoding: .utf8)
        XCTAssertEqual(SSHConfig.loadHostsCached(home: home), ["alpha", "beta", "delta", "gamma"])
    }
}
