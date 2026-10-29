import Foundation
import LabTunnelControl

enum ExitCode {
    static let ok: Int32 = 0
    static let failure: Int32 = 1
    static let usage: Int32 = 2
    static let notFound: Int32 = 3
    static let unreachable: Int32 = 4
    static let connectFailed: Int32 = 5
}

enum CLI {
    static let usage = """
    labtunnel: manage the SSH tunnels of the LabTunnel menu bar app.

    Usage:
      labtunnel list [--group G] [--json]
      labtunnel status [TUNNEL...] [--json]
      labtunnel add --name N --host H --remote-port P [--local-port P] [--scheme http|https|tcp]
                    [--group G] [--connect-on-launch] [--free-port] [--connect] [--json]
      labtunnel update TUNNEL [--name N] [--host H] [--remote-port P] [--local-port P]
                    [--scheme S] [--group G] [--[no-]connect-on-launch] [--[no-]free-port] [--json]
      labtunnel remove TUNNEL... [--json]
      labtunnel connect TUNNEL... | --group G | --all [--no-wait] [--timeout SECONDS] [--json]
      labtunnel disconnect TUNNEL... | --group G | --all [--json]
      labtunnel setup        Install the CLI link and the agent skill for this user

    TUNNEL is a tunnel name (case-insensitive), an id, or an id prefix of at least 4
    characters. Names are unique, ignoring case.
    A tunnel forwards 127.0.0.1:LOCAL to 127.0.0.1:REMOTE on the SSH host.
    The local port defaults to the remote port. HOST is anything ssh accepts, such as a
    ~/.ssh/config alias. Authentication must work without prompts (keys or an agent).

    If the app is not running, the first command starts it in the background.
    `connect` waits until each tunnel is up or has failed (default timeout 20s).
    With --json, every command prints one JSON object: {ok, tunnels[]}, plus error and
    code on failure. Fields without a value are left out.
    Tunnel fields: id name host remotePort localPort scheme group connectOnLaunch
    useFreePortIfBusy state error activeLocalPort url remote traffic{up,down,upRate,downRate}.
    state is idle|connecting|connected|reconnecting|failed. remote is
    unknown|listening|notListening.

    Exit codes: 0 ok, 1 error, 2 usage, 3 tunnel not found or ambiguous,
                4 app unreachable, 5 a tunnel failed or timed out while connecting.
    """

    static func run(arguments: [String], client: ControlClient = ControlClient()) -> Int32 {
        let invocation: Invocation
        do {
            invocation = try Parsing.parse(arguments)
        } catch let error as UsageError {
            printError("\(error.message) Run 'labtunnel help' for usage.")
            return ExitCode.usage
        } catch {
            printError("\(error)")
            return ExitCode.usage
        }

        switch invocation {
        case .help:
            print(usage)
            return ExitCode.ok
        case .setup:
            return runSetup()
        case .request(let request, let options):
            return execute(request, options, client: client)
        }
    }

    // MARK: Requests

    private static func execute(_ request: ControlRequest, _ options: Options, client: ControlClient) -> Int32 {
        do {
            try ensureAppRunning(client)
            var response = try client.send(request)
            let started = response.ok && startsConnection(request, response)
            var timedOut = false
            if started, options.wait {
                (response, timedOut) = try waitForConnections(response, options: options, client: client)
            }
            return report(response, for: request, options: options, connecting: started, timedOut: timedOut)
        } catch let error as ControlClient.Failure {
            return fail(error.description, code: "unreachable", json: options.json, exit: ExitCode.unreachable)
        } catch {
            return fail("\(error)", code: "internal", json: options.json, exit: ExitCode.failure)
        }
    }

    /// True when the request brought tunnels up, or tried to: connect, add --connect, and an
    /// update that reconnected a live tunnel. Decides whether to wait, and whether a failed
    /// tunnel fails the command.
    private static func startsConnection(_ request: ControlRequest, _ response: ControlResponse) -> Bool {
        switch request.command {
        case "connect": true
        case "add": request.connect
        case "update":
            // The app resets a tunnel when its connection changes, then reconnects it if it
            // was live. So "connecting" is the reconnect, and "failed" is a reconnect that
            // failed at once, such as a busy local port.
            request.fields.changesConnection
                && response.tunnels.contains { $0.state == "connecting" || $0.state == "failed" }
        default: false
        }
    }

    private static func report(_ response: ControlResponse, for request: ControlRequest,
                               options: Options, connecting: Bool, timedOut: Bool) -> Int32 {
        guard response.ok else {
            let exit: Int32 = switch response.code {
            case "not_found", "ambiguous": ExitCode.notFound
            case "usage", "invalid", "exists": ExitCode.usage
            default: ExitCode.failure
            }
            if options.json {
                print(Rendering.json(response))
            } else {
                printError(response.error ?? "Request failed.")
            }
            return exit
        }

        let failedAny = connecting && response.tunnels.contains { $0.state == "failed" }
        let exit = (failedAny || timedOut) ? ExitCode.connectFailed : ExitCode.ok

        if options.json {
            var shown = response
            if timedOut { shown.error = "Timed out waiting for the tunnel to connect." }
            print(Rendering.json(shown))
            return exit
        }

        switch request.command {
        case "list":
            print(Rendering.table(response.tunnels))
        case "status":
            if response.tunnels.count == 1 { print(Rendering.detail(response.tunnels[0])) }
            else { print(Rendering.table(response.tunnels)) }
        case "add":
            response.tunnels.forEach { print(connecting ? Rendering.connectResult($0) : Rendering.summary(verb: "added", $0)) }
        case "update":
            response.tunnels.forEach {
                print(Rendering.summary(verb: "updated", $0) + ($0.state == "idle" ? "" : ", now \($0.state)"))
            }
        case "remove":
            response.tunnels.forEach { print("removed \($0.name)") }
        case "connect":
            response.tunnels.forEach { print(Rendering.connectResult($0)) }
        case "disconnect":
            response.tunnels.forEach { print("disconnected \($0.name)") }
        default:
            break
        }
        if timedOut { printError("Timed out waiting for the tunnel to connect.") }
        return exit
    }

    /// Polls until every tunnel is connected (with its remote check done) or has failed.
    private static func waitForConnections(
        _ initial: ControlResponse, options: Options, client: ControlClient
    ) throws -> (ControlResponse, Bool) {
        let ids = initial.tunnels.map(\.id)
        guard !ids.isEmpty else { return (initial, false) }
        let deadline = Date().addingTimeInterval(options.timeout)
        var settledAt: Date?
        var latest = initial

        while true {
            latest = try client.send(ControlRequest(command: "status", targets: ids))
            guard latest.ok else { return (latest, false) }

            let settled = latest.tunnels.allSatisfy { ["connected", "failed", "idle"].contains($0.state) }
            if settled {
                // Connected tunnels probe the remote port a moment later; give that a few seconds.
                settledAt = settledAt ?? Date()
                let probed = latest.tunnels.allSatisfy { $0.state != "connected" || $0.remote != "unknown" }
                if probed || Date().timeIntervalSince(settledAt!) > 4 { return (latest, false) }
            } else {
                settledAt = nil
            }
            if Date() > deadline { return (latest, true) }
            Thread.sleep(forTimeInterval: 0.25)
        }
    }

    // MARK: App lifecycle

    private static func ensureAppRunning(_ client: ControlClient) throws {
        if client.isRunning() { return }
        launchApp()
        for _ in 0..<60 {  // up to 15 seconds
            Thread.sleep(forTimeInterval: 0.25)
            if client.isRunning() { return }
        }
        throw ControlClient.Failure.unreachable("the app did not start. Open LabTunnel.app manually and retry.")
    }

    /// Starts the app without stealing focus. Prefers the bundle this CLI lives in, so a copy in
    /// /Applications wins over any other registered build.
    private static func launchApp() {
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        if let bundle = enclosingAppBundle() {
            open.arguments = ["-g", bundle.path]
        } else {
            open.arguments = ["-g", "-b", ControlPaths.appBundleIdentifier]
        }
        open.standardOutput = FileHandle.nullDevice
        open.standardError = FileHandle.nullDevice
        try? open.run()
        open.waitUntilExit()
    }

    /// `<App>.app` when this binary sits at `<App>.app/Contents/Helpers/labtunnel`.
    static func enclosingAppBundle(executable: URL? = Bundle.main.executableURL) -> URL? {
        guard let executable = executable?.resolvingSymlinksInPath() else { return nil }
        let bundle = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let isHelper = executable.deletingLastPathComponent().lastPathComponent == "Helpers"
        return (isHelper && bundle.pathExtension == "app") ? bundle : nil
    }

    // MARK: Setup

    private static func runSetup() -> Int32 {
        guard let bundle = enclosingAppBundle() else {
            printError("setup only works from the installed app. Run it as ~/.local/bin/labtunnel or from LabTunnel.app/Contents/Helpers.")
            return ExitCode.failure
        }
        do {
            let installed = try AgentSetup.install(appBundle: bundle)
            print("CLI:   \(installed.cliLink.path)")
            print("Skill: \(installed.skillFile.path)")
            let binDirectory = installed.cliLink.deletingLastPathComponent().path
            let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
            if !path.split(separator: ":").contains(Substring(binDirectory)) {
                print("Note: \(binDirectory) is not on your PATH. Add it to run `labtunnel` directly.")
            }
            return ExitCode.ok
        } catch {
            printError("\(error)")
            return ExitCode.failure
        }
    }

    // MARK: Output

    private static func fail(_ message: String, code: String, json: Bool, exit: Int32) -> Int32 {
        if json {
            print(Rendering.json(.failure(code, message)))
        } else {
            printError(message)
        }
        return exit
    }

    private static func printError(_ message: String) {
        FileHandle.standardError.write(Data("labtunnel: \(message)\n".utf8))
    }
}

private extension TunnelFields {
    /// Mirrors `Tunnel.sameConnection` in the app: the fields that restart a live tunnel.
    var changesConnection: Bool {
        host != nil || remotePort != nil || localPort != nil || useFreePortIfBusy != nil
    }
}
