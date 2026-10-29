import Foundation
import LabTunnelControl
import XCTest
@testable import LabTunnel
@testable import LabTunnelCLI

// MARK: CLI parsing and rendering

final class CLIParsingTests: XCTestCase {
    private func request(_ args: [String]) throws -> (ControlRequest, Options) {
        guard case .request(let request, let options) = try Parsing.parse(args) else {
            XCTFail("expected a request for \(args)")
            return (ControlRequest(command: ""), Options())
        }
        return (request, options)
    }

    func testAddParsesEveryField() throws {
        let (r, o) = try request(["add", "--name", "Grafana", "--host", "homelab", "--remote-port", "3000",
                                  "--local-port=4000", "--scheme", "HTTPS", "--group", "Media",
                                  "--connect-on-launch", "--free-port", "--connect", "--json"])
        XCTAssertEqual(r.command, "add")
        XCTAssertEqual(r.fields, TunnelFields(name: "Grafana", host: "homelab", remotePort: 3000, localPort: 4000,
                                              scheme: "https", group: "Media", connectOnLaunch: true,
                                              useFreePortIfBusy: true))
        XCTAssertTrue(r.connect)
        XCTAssertTrue(o.json)
    }

    func testAddRequiresNameHostAndRemotePort() {
        XCTAssertThrowsError(try Parsing.parse(["add", "--name", "x", "--host", "h"]))
        XCTAssertThrowsError(try Parsing.parse(["add", "--host", "h", "--remote-port", "1"]))
        XCTAssertThrowsError(try Parsing.parse(["add", "stray", "--name", "x", "--host", "h", "--remote-port", "1"]))
    }

    func testUpdateTakesOneTargetAndAtLeastOneChange() throws {
        let (r, _) = try request(["update", "s1ui", "--local-port", "8080", "--no-free-port"])
        XCTAssertEqual(r.targets, ["s1ui"])
        XCTAssertEqual(r.fields.localPort, 8080)
        XCTAssertEqual(r.fields.useFreePortIfBusy, false)
        XCTAssertThrowsError(try Parsing.parse(["update", "s1ui"]))
        XCTAssertThrowsError(try Parsing.parse(["update", "--host", "h"]))
        XCTAssertThrowsError(try Parsing.parse(["update", "a", "b", "--host", "h"]))
    }

    func testGroupIsAFieldForAddAndAFilterElsewhere() throws {
        let (add, _) = try request(["add", "--name", "n", "--host", "h", "--remote-port", "1", "--group", "G"])
        XCTAssertEqual(add.fields.group, "G")
        XCTAssertNil(add.group)
        let (list, _) = try request(["list", "--group", "G"])
        XCTAssertEqual(list.group, "G")
        XCTAssertNil(list.fields.group)
    }

    func testConnectAndDisconnectNeedATarget() throws {
        XCTAssertThrowsError(try Parsing.parse(["connect"]))
        XCTAssertThrowsError(try Parsing.parse(["disconnect", "--json"]))
        let (all, _) = try request(["connect", "--all"])
        XCTAssertTrue(all.all)
        let (grouped, o) = try request(["connect", "--group", "AI", "--no-wait", "--timeout", "5"])
        XCTAssertEqual(grouped.group, "AI")
        XCTAssertFalse(o.wait)
        XCTAssertEqual(o.timeout, 5)
        let (named, _) = try request(["disconnect", "a", "b"])
        XCTAssertEqual(named.targets, ["a", "b"])
    }

    func testRejectsBadInput() {
        XCTAssertThrowsError(try Parsing.parse(["frobnicate"]))
        XCTAssertThrowsError(try Parsing.parse(["list", "--bogus"]))
        XCTAssertThrowsError(try Parsing.parse(["list", "--host", "h"]), "field flags only apply to add and update")
        XCTAssertThrowsError(try Parsing.parse(["connect", "x", "--connect"]))
        XCTAssertThrowsError(try Parsing.parse(["add", "--remote-port", "70000"]))
        XCTAssertThrowsError(try Parsing.parse(["add", "--remote-port", "abc"]))
        XCTAssertThrowsError(try Parsing.parse(["add", "--scheme", "ftp"]))
        XCTAssertThrowsError(try Parsing.parse(["connect", "x", "--timeout", "0"]))
        XCTAssertThrowsError(try Parsing.parse(["add", "--name"]), "a flag at the end needs its value")
        XCTAssertThrowsError(try Parsing.parse(["remove"]))
    }

    func testHelpAndSetup() throws {
        XCTAssertEqual(try Parsing.parse([]), .help)
        XCTAssertEqual(try Parsing.parse(["--help"]), .help)
        XCTAssertEqual(try Parsing.parse(["setup"]), .setup)
    }

    func testFindsAppBundleFromHelperPathOnly() {
        let helper = URL(fileURLWithPath: "/Applications/LabTunnel.app/Contents/Helpers/labtunnel")
        XCTAssertEqual(CLI.enclosingAppBundle(executable: helper)?.path, "/Applications/LabTunnel.app")
        XCTAssertNil(CLI.enclosingAppBundle(executable: URL(fileURLWithPath: "/usr/local/bin/labtunnel-cli")))
        XCTAssertNil(CLI.enclosingAppBundle(executable: URL(fileURLWithPath: "/Applications/LabTunnel.app/Contents/MacOS/LabTunnel")))
    }

    func testRenderingMentionsFailuresAndClosedRemotePorts() {
        var t = TunnelStatus(id: "1", name: "web", host: "box", remotePort: 80, localPort: 80, scheme: "http",
                             group: "", connectOnLaunch: false, useFreePortIfBusy: false, state: "connected",
                             activeLocalPort: 81, url: "http://127.0.0.1:81", remote: "notListening")
        XCTAssertTrue(Rendering.connectResult(t).contains("http://127.0.0.1:81"))
        XCTAssertTrue(Rendering.connectResult(t).contains("warning"))
        XCTAssertTrue(Rendering.table([t]).contains("127.0.0.1:81"))
        t.state = "failed"
        t.error = "Permission denied"
        XCTAssertEqual(Rendering.connectResult(t), "failed web: Permission denied")
        XCTAssertEqual(Rendering.table([]), "No tunnels.")
    }
}

// MARK: Handler

private func occupyPort() -> (fd: Int32, port: Int) {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    let size = socklen_t(MemoryLayout<sockaddr_in>.size)
    withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = bind(fd, $0, size) } }
    listen(fd, 1)
    var len = size
    withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = getsockname(fd, $0, &len) } }
    return (fd, Int(UInt16(bigEndian: addr.sin_port)))
}

@MainActor
final class ControlHandlerTests: XCTestCase {
    private func makeHandler() -> (ControlHandler, TunnelManager) {
        let store = FileManager.default.temporaryDirectory.appendingPathComponent("lt-\(UUID())/tunnels.json")
        let manager = TunnelManager(storeURL: store)
        return (ControlHandler(manager: manager), manager)
    }

    private func add(_ handler: ControlHandler, _ name: String, port: Int = 3000, group: String? = nil) -> ControlResponse {
        handler.handle(ControlRequest(command: "add", fields: TunnelFields(name: name, host: "homelab", remotePort: port, group: group)))
    }

    func testAddDefaultsLocalPortToRemoteAndSchemeToHTTP() {
        let (handler, manager) = makeHandler()
        let response = add(handler, " Grafana ")
        XCTAssertTrue(response.ok)
        let tunnel = response.tunnels[0]
        XCTAssertEqual(tunnel.name, "Grafana")
        XCTAssertEqual(tunnel.localPort, 3000)
        XCTAssertEqual(tunnel.scheme, "http")
        XCTAssertEqual(tunnel.state, "idle")
        XCTAssertNil(tunnel.url)
        XCTAssertEqual(manager.tunnels.count, 1)
    }

    func testAddRejectsDuplicateNamesAndBadValues() {
        let (handler, manager) = makeHandler()
        _ = add(handler, "Grafana")
        XCTAssertEqual(add(handler, "grafana").code, "exists")
        let badHost = handler.handle(ControlRequest(command: "add", fields: TunnelFields(name: "x", host: "-oProxyCommand=y", remotePort: 1)))
        XCTAssertEqual(badHost.code, "invalid")
        let badScheme = handler.handle(ControlRequest(command: "add", fields: TunnelFields(name: "y", host: "h", remotePort: 1, scheme: "ftp")))
        XCTAssertEqual(badScheme.code, "invalid")
        let missing = handler.handle(ControlRequest(command: "add", fields: TunnelFields(name: "z")))
        XCTAssertEqual(missing.code, "usage")
        XCTAssertEqual(manager.tunnels.count, 1, "failed adds must not leave entries behind")
    }

    func testListFiltersByGroupAndTargets() {
        let (handler, _) = makeHandler()
        _ = add(handler, "a", port: 1, group: "AI")
        _ = add(handler, "b", port: 2)
        XCTAssertEqual(handler.handle(ControlRequest(command: "list")).tunnels.map(\.name), ["a", "b"])
        XCTAssertEqual(handler.handle(ControlRequest(command: "list", group: "ai")).tunnels.map(\.name), ["a"])
        XCTAssertEqual(handler.handle(ControlRequest(command: "status", targets: ["B"])).tunnels.map(\.name), ["b"])
        XCTAssertEqual(handler.handle(ControlRequest(command: "list", group: "nope")).tunnels, [])
    }

    func testUpdateChangesOnlyTheGivenFields() {
        let (handler, manager) = makeHandler()
        _ = add(handler, "web", port: 80, group: "G")
        let response = handler.handle(ControlRequest(command: "update", targets: ["web"],
                                                     fields: TunnelFields(name: "site", localPort: 8080, group: "")))
        XCTAssertTrue(response.ok)
        let t = manager.tunnels[0]
        XCTAssertEqual([t.name, t.host, t.group], ["site", "homelab", ""])
        XCTAssertEqual([t.remotePort, t.localPort], [80, 8080])
    }

    func testUpdateRejectsNameClashesAndEmptyChanges() {
        let (handler, manager) = makeHandler()
        _ = add(handler, "a", port: 1)
        _ = add(handler, "b", port: 2)
        XCTAssertEqual(handler.handle(ControlRequest(command: "update", targets: ["a"], fields: TunnelFields(name: "B"))).code, "exists")
        XCTAssertEqual(handler.handle(ControlRequest(command: "update", targets: ["a"])).code, "usage")
        XCTAssertEqual(handler.handle(ControlRequest(command: "update", targets: ["a", "b"], fields: TunnelFields(host: "x"))).code, "usage")
        XCTAssertEqual(handler.handle(ControlRequest(command: "update", targets: ["a"], fields: TunnelFields(remotePort: 0))).code, "invalid")
        XCTAssertEqual(manager.tunnels.map(\.name), ["a", "b"])
        XCTAssertEqual(manager.tunnels[0].remotePort, 1)
        // Renaming to its own name in a different case is allowed.
        XCTAssertTrue(handler.handle(ControlRequest(command: "update", targets: ["a"], fields: TunnelFields(name: "A"))).ok)
    }

    func testTargetsResolveByNameIdAndIdPrefix() {
        let (handler, manager) = makeHandler()
        _ = add(handler, "web", port: 1)
        let id = manager.tunnels[0].id.uuidString
        for token in ["web", "WEB", id, id.lowercased(), String(id.prefix(8))] {
            XCTAssertEqual(handler.handle(ControlRequest(command: "status", targets: [token])).tunnels.first?.name, "web", token)
        }
        XCTAssertEqual(handler.handle(ControlRequest(command: "status", targets: ["nope"])).code, "not_found")
        XCTAssertEqual(handler.handle(ControlRequest(command: "status", targets: [String(id.prefix(3))])).code, "not_found",
                       "prefixes shorter than 4 characters never match")
    }

    func testDuplicateNamesFromTheUIAreReportedAsAmbiguous() {
        let (handler, manager) = makeHandler()
        manager.save(Tunnel(name: "dup", host: "a", remotePort: 1, localPort: 1))
        manager.save(Tunnel(name: "dup", host: "b", remotePort: 2, localPort: 2))
        let response = handler.handle(ControlRequest(command: "status", targets: ["dup"]))
        XCTAssertEqual(response.code, "ambiguous")
        XCTAssertTrue(response.error!.contains(manager.tunnels[0].id.uuidString))
    }

    func testRemoveDeletesOnlyWhenEveryTargetResolves() {
        let (handler, manager) = makeHandler()
        _ = add(handler, "a", port: 1)
        _ = add(handler, "b", port: 2)
        XCTAssertEqual(handler.handle(ControlRequest(command: "remove", targets: ["a", "ghost"])).code, "not_found")
        XCTAssertEqual(manager.tunnels.count, 2, "nothing is removed when one target is unknown")
        let removed = handler.handle(ControlRequest(command: "remove", targets: ["a"]))
        XCTAssertEqual(removed.tunnels.map(\.name), ["a"])
        XCTAssertEqual(manager.tunnels.map(\.name), ["b"])
        XCTAssertEqual(handler.handle(ControlRequest(command: "remove")).code, "usage")
    }

    func testConnectReportsFailureAndDisconnectResets() {
        let (handler, manager) = makeHandler()
        let busy = occupyPort()
        defer { close(busy.fd) }
        _ = handler.handle(ControlRequest(command: "add", fields: TunnelFields(name: "blocked", host: "homelab", remotePort: 80, localPort: busy.port)))

        let connect = handler.handle(ControlRequest(command: "connect", targets: ["blocked"]))
        XCTAssertEqual(connect.tunnels[0].state, "failed")
        XCTAssertTrue(connect.tunnels[0].error!.contains("already in use"))

        let disconnect = handler.handle(ControlRequest(command: "disconnect", targets: ["blocked"]))
        XCTAssertEqual(disconnect.tunnels[0].state, "idle")
        XCTAssertEqual(manager.tunnels.count, 1)
    }

    func testConnectSelectorsNeedSomethingToSelect() {
        let (handler, _) = makeHandler()
        XCTAssertEqual(handler.handle(ControlRequest(command: "connect")).code, "usage")
        XCTAssertEqual(handler.handle(ControlRequest(command: "connect", group: "none")).code, "not_found")
        XCTAssertTrue(handler.handle(ControlRequest(command: "disconnect", all: true)).ok)
        XCTAssertEqual(handler.handle(ControlRequest(command: "explode")).code, "usage")
    }
}

// MARK: Socket round trip

@MainActor
final class ControlServerTests: XCTestCase {
    /// Unix socket paths are capped at 104 bytes, which the temp directory can exceed.
    private func shortSocketURL() -> URL { URL(fileURLWithPath: "/tmp/lt-\(UUID().uuidString.prefix(8)).sock") }

    private func send(_ client: ControlClient, _ request: ControlRequest) async throws -> ControlResponse {
        try await Task.detached { try client.send(request) }.value
    }

    func testClientTalksToServerOverTheSocket() async throws {
        let socket = shortSocketURL()
        let store = FileManager.default.temporaryDirectory.appendingPathComponent("lt-\(UUID())/tunnels.json")
        let server = ControlServer(manager: TunnelManager(storeURL: store), socketURL: socket)
        try server.start()
        defer { server.stop() }
        let client = ControlClient(socketURL: socket)

        let ping = try await send(client, ControlRequest(command: "ping"))
        XCTAssertTrue(ping.ok)
        let added = try await send(client, ControlRequest(command: "add", fields: TunnelFields(name: "web", host: "homelab", remotePort: 8080)))
        XCTAssertEqual(added.tunnels.first?.localPort, 8080)
        let listed = try await send(client, ControlRequest(command: "list"))
        XCTAssertEqual(listed.tunnels.map(\.name), ["web"])
        let missing = try await send(client, ControlRequest(command: "status", targets: ["ghost"]))
        XCTAssertEqual(missing.code, "not_found")
    }

    func testSocketIsPrivateAndCleanedUp() throws {
        let socket = shortSocketURL()
        let store = FileManager.default.temporaryDirectory.appendingPathComponent("lt-\(UUID())/tunnels.json")
        let server = ControlServer(manager: TunnelManager(storeURL: store), socketURL: socket)
        try server.start()
        let mode = try FileManager.default.attributesOfItem(atPath: socket.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: socket.path))
    }

    func testStartReplacesAStaleSocketFileLeftByACrash() throws {
        let socket = shortSocketURL()
        try Data("stale".utf8).write(to: socket)  // nothing listens here
        let store = FileManager.default.temporaryDirectory.appendingPathComponent("lt-\(UUID())/tunnels.json")
        let server = ControlServer(manager: TunnelManager(storeURL: store), socketURL: socket)
        try server.start()
        defer { server.stop() }
        XCTAssertNotEqual(try FileManager.default.attributesOfItem(atPath: socket.path)[.type] as? FileAttributeType,
                          .typeRegular)
    }

    func testGarbageInputGetsAnErrorNotACrash() async throws {
        let socket = shortSocketURL()
        let store = FileManager.default.temporaryDirectory.appendingPathComponent("lt-\(UUID())/tunnels.json")
        let server = ControlServer(manager: TunnelManager(storeURL: store), socketURL: socket)
        try server.start()
        defer { server.stop() }

        let reply: ControlResponse? = await Task.detached {
            guard let fd = try? UnixSocket.connect(path: socket.path, timeoutSeconds: 5) else { return nil }
            defer { close(fd) }
            UnixSocket.writeLine(fd, Data("this is not json".utf8))
            return UnixSocket.readLine(fd).flatMap { try? JSONDecoder().decode(ControlResponse.self, from: $0) }
        }.value
        XCTAssertEqual(reply?.ok, false)
        XCTAssertEqual(reply?.code, "usage")
    }

    func testClientReportsUnreachableApp() {
        let client = ControlClient(socketURL: shortSocketURL())
        XCTAssertFalse(client.isRunning())
        XCTAssertThrowsError(try client.send(ControlRequest(command: "ping")))
    }

    /// Runs the real CLI against a real server, the way a script would.
    private func startServerForCLI() throws -> (TunnelManager, ControlHandler, ControlClient) {
        let socket = shortSocketURL()
        let manager = TunnelManager(storeURL: temporaryStoreURL(), sshExecutable: try makeFakeSSH())
        let server = ControlServer(manager: manager, socketURL: socket)
        try server.start()
        addTeardownBlock { @MainActor in
            server.stop()
            manager.disconnectAll()
        }
        return (manager, ControlHandler(manager: manager), ControlClient(socketURL: socket))
    }

    private func cli(_ arguments: [String], _ client: ControlClient) async -> Int32 {
        await Task.detached { CLI.run(arguments: arguments, client: client) }.value
    }

    func testCosmeticUpdateOfAFailedTunnelSucceeds() async throws {
        let (_, handler, client) = try startServerForCLI()
        let busy = occupyPort()
        defer { close(busy.fd) }
        _ = handler.handle(ControlRequest(command: "add", fields: TunnelFields(name: "web", host: "box", remotePort: 80, localPort: busy.port)))
        XCTAssertEqual(handler.handle(ControlRequest(command: "connect", targets: ["web"])).tunnels[0].state, "failed")

        let exit = await cli(["update", "web", "--name", "site"], client)
        XCTAssertEqual(exit, ExitCode.ok, "a rename reconnects nothing, so an earlier failure is not this command's")
    }

    func testUpdateFailsOnlyWhenItsOwnReconnectFails() async throws {
        let (manager, handler, client) = try startServerForCLI()
        _ = handler.handle(ControlRequest(command: "add", fields: TunnelFields(name: "live", host: "box", remotePort: 80, localPort: freeLocalPort()), connect: true))
        XCTAssertEqual(manager.tunnels.first.map(manager.state(of:)), .connecting)

        // Renaming a tunnel that is still connecting returns at once instead of waiting for it.
        let renamed = await cli(["update", "live", "--name", "renamed"], client)
        XCTAssertEqual(renamed, ExitCode.ok)

        let busy = occupyPort()
        defer { close(busy.fd) }
        let moved = await cli(["update", "renamed", "--local-port", String(busy.port)], client)
        XCTAssertEqual(moved, ExitCode.connectFailed)
        XCTAssertEqual(manager.tunnels.first.map(manager.state(of:)), .failed("Local port \(busy.port) is already in use."))
    }
}

// MARK: Agent setup

final class AgentSetupTests: XCTestCase {
    private func makeBundleAndHome(helper: Bool = true) throws -> (bundle: URL, home: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lt-setup-\(UUID())")
        let bundle = root.appendingPathComponent("LabTunnel.app")
        let home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Contents/Helpers"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Contents/Resources/skill"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        if helper {
            let url = AgentSetup.helperURL(in: bundle)
            try "#!/bin/sh\n".write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        try "skill v1".write(to: AgentSetup.skillSourceURL(in: bundle), atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (bundle, home)
    }

    func testInstallLinksTheCLIAndCopiesTheSkill() throws {
        let (bundle, home) = try makeBundleAndHome()
        let installed = try AgentSetup.install(appBundle: bundle, home: home)

        XCTAssertEqual(installed.cliLink.path, home.appendingPathComponent(".local/bin/labtunnel").path)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: installed.cliLink.path),
                       AgentSetup.helperURL(in: bundle).path)
        XCTAssertEqual(try String(contentsOf: installed.skillFile, encoding: .utf8), "skill v1")
        XCTAssertEqual(installed.skillFile.path, home.appendingPathComponent(".agents/skills/labtunnel/SKILL.md").path)
    }

    func testReinstallRepointsTheLinkAndRefreshesTheSkill() throws {
        let (bundle, home) = try makeBundleAndHome()
        _ = try AgentSetup.install(appBundle: bundle, home: home)
        try "skill v2".write(to: AgentSetup.skillSourceURL(in: bundle), atomically: true, encoding: .utf8)
        let again = try AgentSetup.install(appBundle: bundle, home: home)
        XCTAssertEqual(try String(contentsOf: again.skillFile, encoding: .utf8), "skill v2")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: again.cliLink.path),
                       AgentSetup.helperURL(in: bundle).path)
    }

    func testNeverOverwritesARealFileAtTheLinkPath() throws {
        let (bundle, home) = try makeBundleAndHome()
        let link = home.appendingPathComponent(".local/bin/labtunnel")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "mine".write(to: link, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try AgentSetup.install(appBundle: bundle, home: home))
        XCTAssertEqual(try String(contentsOf: link, encoding: .utf8), "mine")
    }

    func testFailsClearlyWhenTheBundleLacksTheHelper() throws {
        let (bundle, home) = try makeBundleAndHome(helper: false)
        XCTAssertThrowsError(try AgentSetup.install(appBundle: bundle, home: home)) {
            XCTAssertTrue("\($0)".contains("helper"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".local").path),
                       "a failed setup must not leave partial state behind")
    }
}
