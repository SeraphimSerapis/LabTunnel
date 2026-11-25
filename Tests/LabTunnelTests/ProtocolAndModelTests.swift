import Darwin
import Foundation
import LabTunnelControl
import XCTest
@testable import LabTunnel

final class ProtocolAndModelTests: XCTestCase {
    // MARK: Tunnel remoteHost

    func testDecodesLegacyTunnelWithoutRemoteHostAsLoopback() throws {
        let json = """
        {"id":"11111111-1111-1111-1111-111111111111","name":"Old","host":"box","remotePort":80,"localPort":8080}
        """
        let tunnel = try JSONDecoder().decode(Tunnel.self, from: Data(json.utf8))
        XCTAssertEqual(tunnel.remoteHost, "127.0.0.1")
    }

    func testRoundTripPreservesCustomIPv4AndIPv6RemoteHost() throws {
        for remoteHost in ["10.0.0.5", "::1", "fd00::42"] {
            let tunnel = Tunnel(
                name: "SVC",
                host: "jump",
                remotePort: 8080,
                localPort: 8081,
                scheme: .https,
                group: "Infra",
                connectOnLaunch: true,
                useFreePortIfBusy: true,
                remoteHost: remoteHost
            )
            let encoded = try JSONEncoder().encode(tunnel)
            let decoded = try JSONDecoder().decode(Tunnel.self, from: encoded)
            XCTAssertEqual(decoded, tunnel)
            XCTAssertEqual(decoded.remoteHost, remoteHost)
        }
    }

    func testSSHArgumentsDisableForwardingAndBracketIPv6RemoteHost() {
        let ipv4 = Tunnel(name: "A", host: "jump", remotePort: 5432, localPort: 5432, remoteHost: "10.0.0.5")
        let args4 = ipv4.sshArguments(localPort: 5432)
        XCTAssertTrue(args4.contains("-a"))
        XCTAssertTrue(args4.contains("-x"))
        XCTAssertEqual(args4[args4.firstIndex(of: "-L")! + 1], "127.0.0.1:5432:10.0.0.5:5432")
        XCTAssertEqual(Array(args4.suffix(2)), ["--", "jump"])

        let ipv6Unbracketed = Tunnel(name: "B", host: "jump", remotePort: 80, localPort: 8080, remoteHost: "fd00::1")
        let args6 = ipv6Unbracketed.sshArguments(localPort: 8080)
        XCTAssertEqual(args6[args6.firstIndex(of: "-L")! + 1], "127.0.0.1:8080:[fd00::1]:80")

        let ipv6Bracketed = Tunnel(name: "C", host: "jump", remotePort: 80, localPort: 8080, remoteHost: "[::1]")
        let args6b = ipv6Bracketed.sshArguments(localPort: 8080)
        XCTAssertEqual(args6b[args6b.firstIndex(of: "-L")! + 1], "127.0.0.1:8080:[::1]:80")
    }

    func testSameConnectionIncludesRemoteHost() {
        let base = Tunnel(name: "A", host: "jump", remotePort: 80, localPort: 8080, remoteHost: "127.0.0.1")
        var differentRemoteHost = base
        differentRemoteHost.remoteHost = "10.0.0.2"
        XCTAssertFalse(base.sameConnection(as: differentRemoteHost))

        var sameConnDifferentMeta = base
        sameConnDifferentMeta.name = "Renamed"
        sameConnDifferentMeta.scheme = .tcp
        sameConnDifferentMeta.group = "Other"
        sameConnDifferentMeta.connectOnLaunch = true
        XCTAssertTrue(base.sameConnection(as: sameConnDifferentMeta))
    }

    func testRouteFormatsDefaultAndCustomRemoteHost() {
        let loopback = Tunnel(name: "A", host: "homelab", remotePort: 3000, localPort: 3000)
        XCTAssertEqual(loopback.route(localPort: 3001), "homelab:3000 → localhost:3001")

        let forwarded = Tunnel(name: "B", host: "bastion", remotePort: 5432, localPort: 15432, remoteHost: "db.internal")
        XCTAssertEqual(forwarded.route(localPort: 15432), "bastion → db.internal:5432 → localhost:15432")
    }

    func testValidateRemoteHost() {
        XCTAssertNil(Tunnel.validate(name: "A", host: "jump", remotePort: 80, localPort: 8080))
        XCTAssertNil(Tunnel.validate(name: "A", host: "jump", remoteHost: "10.0.0.5", remotePort: 80, localPort: 8080))
        XCTAssertNil(Tunnel.validate(name: "A", host: "jump", remoteHost: "::1", remotePort: 80, localPort: 8080))
        XCTAssertNil(Tunnel.validate(name: "A", host: "jump", remoteHost: "[fd00::1]", remotePort: 80, localPort: 8080))

        for bad in ["", "   ", "-oProxyCommand=x", "bad host", "bad\nhost", "bad\0host", "a/b", "a;b"] {
            XCTAssertNotNil(
                Tunnel.validate(name: "A", host: "jump", remoteHost: bad, remotePort: 80, localPort: 8080),
                "Expected rejection for remoteHost: \(bad.debugDescription)"
            )
        }
    }

    // MARK: Protocol compatibility

    func testProtocolAdditiveFieldsEncodeAndDecode() throws {
        let reqJSON = #"{"command":"connect","targets":["web"],"group":null,"all":false,"fields":{},"connect":false}"#
        let decodedReq = try JSONDecoder().decode(ControlRequest.self, from: Data(reqJSON.utf8))
        XCTAssertNil(decodedReq.timeout)
        XCTAssertNil(decodedReq.fields.remoteHost)

        let fields = TunnelFields(name: "api", host: "box", remotePort: 80, remoteHost: "10.0.0.2")
        let req = ControlRequest(command: "connect", targets: ["api"], fields: fields, timeout: 12.5)
        let roundTripReq = try JSONDecoder().decode(ControlRequest.self, from: JSONEncoder().encode(req))
        XCTAssertEqual(roundTripReq, req)

        let status = TunnelStatus(
            id: "1",
            name: "api",
            host: "box",
            remotePort: 80,
            localPort: 8080,
            scheme: "http",
            group: "",
            connectOnLaunch: false,
            useFreePortIfBusy: false,
            state: "connected",
            remoteHost: "10.0.0.2",
            uptimeSeconds: 42
        )
        let response = ControlResponse(ok: true, tunnels: [status], hosts: ["box"], version: "1.2.3")
        let roundTripResp = try JSONDecoder().decode(ControlResponse.self, from: JSONEncoder().encode(response))
        XCTAssertEqual(roundTripResp, response)

        XCTAssertTrue(ControlPaths.defaultDirectoryURL.hasDirectoryPath)
        XCTAssertEqual(ControlPaths.defaultSocketURL.deletingLastPathComponent(), ControlPaths.defaultDirectoryURL)
        XCTAssertEqual(ControlPaths.defaultLockURL, ControlPaths.defaultDirectoryURL.appendingPathComponent("instance.lock"))
    }

    // MARK: InstanceLock

    func testInstanceLockMutualExclusionReleaseAndReacquire() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lt-lock-\(UUID())")
        let lockURL = dir.appendingPathComponent("nested/instance.lock")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        let first = InstanceLock.acquire(at: lockURL)
        XCTAssertNotNil(first)
        XCTAssertNil(InstanceLock.acquire(at: lockURL), "second lock must fail while first is held")

        first?.release()
        let second = InstanceLock.acquire(at: lockURL)
        XCTAssertNotNil(second, "lock must be acquirable again after release")

        // Releasing the first handle a second time must be a no-op and leave `second` intact.
        first?.release()
        XCTAssertNil(InstanceLock.acquire(at: lockURL))

        second?.release()
        let third = InstanceLock.acquire(at: lockURL)
        XCTAssertNotNil(third)
        third?.release()
    }

    // MARK: AgentSetup status

    private func makeBundleAndHome() throws -> (root: URL, bundle: URL, otherBundle: URL, home: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lt-status-\(UUID())")
        let bundle = root.appendingPathComponent("LabTunnel.app")
        let otherBundle = root.appendingPathComponent("Other.app")
        let home = root.appendingPathComponent("home")
        let fm = FileManager.default

        for b in [bundle, otherBundle] {
            try fm.createDirectory(at: b.appendingPathComponent("Contents/Helpers"), withIntermediateDirectories: true)
            try fm.createDirectory(at: b.appendingPathComponent("Contents/Resources/skill"), withIntermediateDirectories: true)
            let helper = AgentSetup.helperURL(in: b)
            try "#!/bin/sh\n".write(to: helper, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
            try "skill v1".write(to: AgentSetup.skillSourceURL(in: b), atomically: true, encoding: .utf8)
        }
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { try? fm.removeItem(at: root) }
        return (root, bundle, otherBundle, home)
    }

    func testAgentSetupStatusTransitions() throws {
        let (_, bundle, otherBundle, home) = try makeBundleAndHome()
        let fm = FileManager.default

        let missing = AgentSetup.status(appBundle: bundle, home: home)
        XCTAssertFalse(missing.cliInstalled)
        XCTAssertFalse(missing.cliMatchesBundle)
        XCTAssertFalse(missing.skillInstalled)
        XCTAssertFalse(missing.skillUpToDate)
        XCTAssertFalse(missing.isComplete)
        XCTAssertEqual(missing.cliLink.path, home.appendingPathComponent(".local/bin/labtunnel").path)
        XCTAssertEqual(missing.skillFile.path, home.appendingPathComponent(".agents/skills/labtunnel/SKILL.md").path)

        _ = try AgentSetup.install(appBundle: bundle, home: home)
        let installed = AgentSetup.status(appBundle: bundle, home: home)
        XCTAssertTrue(installed.cliInstalled)
        XCTAssertTrue(installed.cliMatchesBundle)
        XCTAssertTrue(installed.skillInstalled)
        XCTAssertTrue(installed.skillUpToDate)
        XCTAssertTrue(installed.isComplete)

        let noBundle = AgentSetup.status(appBundle: nil, home: home)
        XCTAssertTrue(noBundle.isComplete)

        // Outdated skill
        try "skill v2".write(to: AgentSetup.skillSourceURL(in: bundle), atomically: true, encoding: .utf8)
        let outdated = AgentSetup.status(appBundle: bundle, home: home)
        XCTAssertTrue(outdated.cliInstalled)
        XCTAssertTrue(outdated.cliMatchesBundle)
        XCTAssertTrue(outdated.skillInstalled)
        XCTAssertFalse(outdated.skillUpToDate)
        XCTAssertFalse(outdated.isComplete)

        // Mismatched CLI symlink pointing to a different bundle's helper
        let mismatched = AgentSetup.status(appBundle: otherBundle, home: home)
        XCTAssertTrue(mismatched.cliInstalled)
        XCTAssertFalse(mismatched.cliMatchesBundle)
        XCTAssertFalse(mismatched.isComplete)

        // Regular file instead of symlink must not count as installed
        try fm.removeItem(at: installed.cliLink)
        try "#!/bin/sh\n".write(to: installed.cliLink, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installed.cliLink.path)
        let regularFile = AgentSetup.status(appBundle: bundle, home: home)
        XCTAssertFalse(regularFile.cliInstalled)
        XCTAssertFalse(regularFile.cliMatchesBundle)
        XCTAssertFalse(regularFile.isComplete)
    }

    // MARK: UnixSocket.readLine and ControlClient

    private func makeSocketPair() throws -> (reader: Int32, writer: Int32) {
        var fds: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        return (fds[0], fds[1])
    }

    func testReadLineHandlesLargeLinesAndChunkedWrites() throws {
        let (reader, writer) = try makeSocketPair()
        defer { close(reader) }
        UnixSocket.configure(reader, timeoutSeconds: 5)

        let payload = Data(repeating: UInt8(ascii: "x"), count: 128 * 1024)
        let writerQueue = DispatchQueue(label: "test.readline.chunked")
        writerQueue.async {
            let chunkSize = 1500
            var offset = 0
            while offset < payload.count {
                let end = min(offset + chunkSize, payload.count)
                let slice = payload[offset..<end]
                slice.withUnsafeBytes { buf in
                    var sent = 0
                    while sent < buf.count {
                        let n = Darwin.write(writer, buf.baseAddress! + sent, buf.count - sent)
                        if n <= 0 { break }
                        sent += n
                    }
                }
                offset = end
                usleep(200)
            }
            var nl: UInt8 = 0x0A
            _ = Darwin.write(writer, &nl, 1)
            close(writer)
        }

        let line = UnixSocket.readLine(reader)
        XCTAssertEqual(line, payload)
    }

    func testReadLineEOFBehavior() throws {
        let (reader1, writer1) = try makeSocketPair()
        defer { close(reader1) }
        close(writer1)
        XCTAssertNil(UnixSocket.readLine(reader1), "empty EOF returns nil")

        let (reader2, writer2) = try makeSocketPair()
        defer { close(reader2) }
        let partial = Data("eof-without-newline".utf8)
        partial.withUnsafeBytes { _ = Darwin.write(writer2, $0.baseAddress!, $0.count) }
        close(writer2)
        XCTAssertEqual(UnixSocket.readLine(reader2), partial, "EOF after data returns buffered bytes")
    }

    func testReadLineTimeoutWithPartialDataReturnsNil() throws {
        let (reader, writer) = try makeSocketPair()
        defer {
            close(reader)
            close(writer)
        }
        UnixSocket.configure(reader, timeoutSeconds: 1)

        let partial = Data("partial-no-newline".utf8)
        partial.withUnsafeBytes { _ = Darwin.write(writer, $0.baseAddress!, $0.count) }

        XCTAssertNil(UnixSocket.readLine(reader), "timeout must return nil instead of truncated partial data")
    }

    func testReadLineRejectsOversizedLine() throws {
        let (reader, writer) = try makeSocketPair()
        defer { close(reader) }
        UnixSocket.configure(reader, timeoutSeconds: 2)

        DispatchQueue.global().async {
            UnixSocket.writeLine(writer, Data(repeating: UInt8(ascii: "a"), count: 200))
            close(writer)
        }
        XCTAssertNil(UnixSocket.readLine(reader, maxBytes: 100))
    }

    func testControlClientIsRunningFastFailsOnUnreachableSocket() {
        let socket = URL(fileURLWithPath: "/tmp/lt-missing-\(UUID().uuidString.prefix(8)).sock")
        let client = ControlClient(socketURL: socket)
        XCTAssertFalse(client.isRunning())
    }
}
