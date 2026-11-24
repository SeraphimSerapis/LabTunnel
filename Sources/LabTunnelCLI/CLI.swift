import Darwin
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
    enum SSHAgentStatus: Equatable {
        case loaded(Int)
        case noKeys
        case noAgent
        case error(Int32)
    }

    static let usage = """
    labtunnel: manage the SSH tunnels of the LabTunnel menu bar app.

    Usage:
      labtunnel list [--group G] [--json]
      labtunnel status [TUNNEL...] [--json]
      labtunnel add --name N --host H --remote-port P [--local-port P] [--remote-host ADDR]
                    [--scheme http|https|tcp] [--group G] [--connect-on-launch] [--free-port]
                    [--connect] [--json]
      labtunnel update TUNNEL [--name N] [--host H] [--remote-port P] [--local-port P]
                    [--remote-host ADDR] [--scheme S] [--group G] [--[no-]connect-on-launch]
                    [--[no-]free-port] [--json]
      labtunnel remove TUNNEL... [--json]
      labtunnel connect TUNNEL... | --group G | --all [--no-wait] [--timeout SECONDS] [--json]
      labtunnel disconnect TUNNEL... | --group G | --all [--json]
      labtunnel open TUNNEL [--no-connect] [--timeout SECONDS] [--json]
      labtunnel recheck TUNNEL... | --group G | --all [--json]
      labtunnel hosts [--json]
      labtunnel doctor [--json]
      labtunnel version [--json]       (also --version or -v)
      labtunnel setup                  Install the CLI link and the agent skill for this user

    TUNNEL is a tunnel name (case-insensitive), an id, or an id prefix of at least 4
    characters. Names are unique, ignoring case. Use `--` to stop option parsing before
    tunnel names starting with `-`.
    A tunnel forwards 127.0.0.1:LOCAL to REMOTE_HOST:REMOTE on the SSH host.
    The local port defaults to the remote port; --remote-host defaults to 127.0.0.1.
    HOST is anything ssh accepts, such as a ~/.ssh/config alias. Authentication must work
    without prompts (keys or an agent).

    If the app is not running, commands that talk to it start it in the background.
    `connect` and `open` wait until each tunnel is up or has failed (default timeout 20s).
    With --json, commands print one JSON object: {ok, tunnels[]}, plus error and code on
    failure (`hosts` adds hosts[], `version` uses {ok, version, appVersion}, `doctor` uses
    {ok, checks[]}). Fields without a value are left out.
    Tunnel fields: id name host remoteHost remotePort localPort scheme group connectOnLaunch
    useFreePortIfBusy state error activeLocalPort url remote uptimeSeconds
    traffic{up,down,upRate,downRate}.
    state is idle|connecting|connected|reconnecting|failed. remote is
    unknown|listening|notListening.

    Exit codes: 0 ok, 1 error, 2 usage, 3 tunnel not found or ambiguous,
                4 app unreachable, 5 a tunnel failed or timed out while connecting.
    """

    static func run(
        arguments: [String],
        client: ControlClient = ControlClient(),
        openURL: (String) -> Bool = openBrowserURL
    ) -> Int32 {
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
        case .version(let json):
            return runVersion(json: json, client: client)
        case .doctor(let json):
            return runDoctor(json: json, client: client)
        case .open(let target, let connectIfIdle, let options):
            return runOpen(target: target, connectIfIdle: connectIfIdle, options: options, client: client, openURL: openURL)
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
            } else if request.command == "recheck", response.ok {
                response = try waitForRecheck(response, client: client)
            }
            return report(response, for: request, options: options, connecting: started, timedOut: timedOut)
        } catch let error as ControlClient.Failure {
            return fail(error.description, code: "unreachable", json: options.json, exit: ExitCode.unreachable)
        } catch {
            return fail("\(error)", code: "internal", json: options.json, exit: ExitCode.failure)
        }
    }

    private static func runOpen(
        target: String,
        connectIfIdle: Bool,
        options: Options,
        client: ControlClient,
        openURL: (String) -> Bool
    ) -> Int32 {
        do {
            try ensureAppRunning(client)
            var response = try client.send(ControlRequest(command: "status", targets: [target]))
            guard response.ok else {
                return reportFailure(response, json: options.json)
            }
            guard var tunnel = response.tunnels.first else {
                return fail("No tunnel named or with id '\(target)'.", code: "not_found", json: options.json, exit: ExitCode.notFound)
            }

            var timedOut = false
            if tunnel.state == "idle" || tunnel.state == "failed" {
                if connectIfIdle {
                    response = try client.send(ControlRequest(command: "connect", targets: [tunnel.id]))
                    guard response.ok else {
                        return reportFailure(response, json: options.json)
                    }
                    if options.wait {
                        (response, timedOut) = try waitForConnections(response, options: options, client: client)
                        guard response.ok else {
                            return reportFailure(response, json: options.json)
                        }
                    }
                    tunnel = response.tunnels.first ?? tunnel
                }
            } else if (tunnel.state == "connecting" || tunnel.state == "reconnecting"), options.wait {
                (response, timedOut) = try waitForConnections(response, options: options, client: client)
                guard response.ok else {
                    return reportFailure(response, json: options.json)
                }
                tunnel = response.tunnels.first ?? tunnel
            }

            if timedOut {
                if options.json {
                    var shown = response
                    shown.error = "Timed out waiting for the tunnel to connect."
                    print(Rendering.json(shown))
                } else {
                    printError("Timed out waiting for the tunnel to connect.")
                }
                return ExitCode.connectFailed
            }

            if tunnel.state == "failed" {
                if options.json {
                    print(Rendering.json(response))
                } else {
                    printError(Rendering.connectResult(tunnel))
                }
                return ExitCode.connectFailed
            }

            if tunnel.state != "connected" {
                let message = "Tunnel '\(tunnel.name)' is \(tunnel.state) and cannot be opened."
                if options.json {
                    var shown = response
                    shown.ok = false
                    shown.code = "connect_failed"
                    shown.error = message
                    print(Rendering.json(shown))
                } else {
                    printError(message)
                }
                return ExitCode.connectFailed
            }

            guard tunnel.scheme != "tcp", let url = tunnel.url else {
                let address = Rendering.local(tunnel)
                let message = "\(tunnel.name) is a \(tunnel.scheme) tunnel and has no browser URL. Connect to \(address)."
                if options.json {
                    var shown = response
                    shown.ok = false
                    shown.code = "usage"
                    shown.error = message
                    print(Rendering.json(shown))
                } else {
                    printError(message)
                }
                return ExitCode.usage
            }

            guard openURL(url) else {
                return fail("Failed to open \(url).", code: "internal", json: options.json, exit: ExitCode.failure)
            }

            if options.json {
                print(Rendering.json(response))
            } else {
                print(url)
            }
            return ExitCode.ok
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

    private static func reportFailure(_ response: ControlResponse, json: Bool) -> Int32 {
        let exit: Int32 = switch response.code {
        case "not_found", "ambiguous": ExitCode.notFound
        case "usage", "invalid", "exists": ExitCode.usage
        default: ExitCode.failure
        }
        if json {
            print(Rendering.json(response))
        } else {
            printError(response.error ?? "Request failed.")
        }
        return exit
    }

    private static func report(_ response: ControlResponse, for request: ControlRequest,
                               options: Options, connecting: Bool, timedOut: Bool) -> Int32 {
        guard response.ok else {
            return reportFailure(response, json: options.json)
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
        case "status", "recheck":
            if response.tunnels.count == 1 { print(Rendering.detail(response.tunnels[0])) }
            else { print(Rendering.table(response.tunnels)) }
        case "add":
            response.tunnels.forEach { print(connecting ? Rendering.connectResult($0) : Rendering.summary(verb: "added", $0)) }
        case "update":
            response.tunnels.forEach {
                let suffix: String = switch $0.state {
                case "idle": ""
                case "failed": ", now failed: \($0.error ?? "unknown error")"
                default: ", now \($0.state)"
                }
                print(Rendering.summary(verb: "updated", $0) + suffix)
            }
        case "remove":
            response.tunnels.forEach { print("removed \($0.name)") }
        case "connect":
            response.tunnels.forEach { print(Rendering.connectResult($0)) }
        case "disconnect":
            response.tunnels.forEach { print("disconnected \($0.name)") }
        case "hosts":
            print(Rendering.hosts(response.hosts ?? []))
        default:
            break
        }
        if timedOut { printError("Timed out waiting for the tunnel to connect.") }
        return exit
    }

    /// Waits via server-side `wait` when supported, falling back to adaptive polling on older binaries.
    static func waitForConnections(
        _ initial: ControlResponse, options: Options, client: ControlClient
    ) throws -> (ControlResponse, Bool) {
        let ids = initial.tunnels.map(\.id)
        guard !ids.isEmpty else { return (initial, false) }

        let socketTimeout = max(10, Int(ceil(options.timeout)) + 10)
        let serverWait = try client.send(
            ControlRequest(command: "wait", targets: ids, timeout: options.timeout),
            timeoutSeconds: socketTimeout
        )
        if serverWait.ok {
            return (serverWait, serverWait.code == "timeout")
        }
        if serverWait.code != "usage" {
            return (serverWait, false)
        }

        let start = ProcessInfo.processInfo.systemUptime
        let deadline = start + options.timeout
        var settledAt: TimeInterval?
        var latest = initial
        let delays = [0.05, 0.10, 0.15, 0.20]
        var attempt = 0

        while true {
            latest = try client.send(ControlRequest(command: "status", targets: ids))
            guard latest.ok else { return (latest, false) }

            let now = ProcessInfo.processInfo.systemUptime
            let settled = latest.tunnels.allSatisfy { ["connected", "failed", "idle"].contains($0.state) }
            if settled {
                // Connected tunnels probe the remote port a moment later; give that a few seconds.
                settledAt = settledAt ?? now
                let probed = latest.tunnels.allSatisfy { $0.state != "connected" || $0.remote != "unknown" }
                if probed || (now - settledAt!) > 4 { return (latest, false) }
            } else {
                settledAt = nil
            }
            if now >= deadline {
                // Never report timeout when every tunnel is already settled and only the remote probe is pending.
                return (latest, !settled)
            }
            let delay = delays[min(attempt, delays.count - 1)]
            attempt += 1
            Thread.sleep(forTimeInterval: delay)
        }
    }

    private static func waitForRecheck(_ initial: ControlResponse, client: ControlClient) throws -> ControlResponse {
        let allIDs = initial.tunnels.map(\.id)
        let connectedIDs = Set(initial.tunnels.filter { $0.state == "connected" }.map(\.id))
        guard !connectedIDs.isEmpty else { return initial }

        let deadline = ProcessInfo.processInfo.systemUptime + 1.6
        var latest = initial
        while ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.1)
            let polled = try client.send(ControlRequest(command: "status", targets: allIDs))
            guard polled.ok else { return latest }
            latest = polled
            let done = latest.tunnels
                .filter { connectedIDs.contains($0.id) }
                .allSatisfy { $0.state != "connected" || $0.remote != "unknown" }
            if done { break }
        }
        return latest
    }

    // MARK: App lifecycle

    private static func ensureAppRunning(_ client: ControlClient) throws {
        if client.isRunning() { return }
        launchApp()
        let deadline = ProcessInfo.processInfo.systemUptime + 15.0
        let delays = [0.05, 0.05, 0.10, 0.15, 0.25]
        var attempt = 0
        while ProcessInfo.processInfo.systemUptime < deadline {
            let delay = delays[min(attempt, delays.count - 1)]
            attempt += 1
            Thread.sleep(forTimeInterval: delay)
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

    private static func openBrowserURL(_ url: String) -> Bool {
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = [url]
        open.standardOutput = FileHandle.nullDevice
        open.standardError = FileHandle.nullDevice
        do {
            try open.run()
            open.waitUntilExit()
            return open.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// `<App>.app` when this binary sits at `<App>.app/Contents/Helpers/labtunnel`.
    static func enclosingAppBundle(executable: URL? = Bundle.main.executableURL) -> URL? {
        guard let executable = executable?.resolvingSymlinksInPath() else { return nil }
        let bundle = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let isHelper = executable.deletingLastPathComponent().lastPathComponent == "Helpers"
        return (isHelper && bundle.pathExtension == "app") ? bundle : nil
    }

    static func bundleVersion(in appBundle: URL?) -> String {
        guard let appBundle else { return "0.1.0" }
        let plistURL = appBundle.appendingPathComponent("Contents/Info.plist")
        if let data = try? Data(contentsOf: plistURL),
           let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let version = dict["CFBundleShortVersionString"] as? String,
           !version.isEmpty {
            return version
        }
        return "0.1.0"
    }

    // MARK: Version, Doctor, Setup

    static func runVersion(
        json: Bool,
        client: ControlClient,
        appBundle: URL? = enclosingAppBundle()
    ) -> Int32 {
        let cliVersion = bundleVersion(in: appBundle)
        let appVersion: String? = client.isRunning()
            ? (try? client.send(ControlRequest(command: "version"), timeoutSeconds: 2))?.version
            : nil

        if json {
            print(Rendering.jsonValue(VersionReport(ok: true, version: cliVersion, appVersion: appVersion)))
        } else if let appVersion, appVersion != cliVersion {
            print("labtunnel \(cliVersion) (app \(appVersion))")
        } else {
            print("labtunnel \(cliVersion)")
        }
        return ExitCode.ok
    }

    static func collectDoctorReport(
        client: ControlClient,
        appBundle: URL? = enclosingAppBundle(),
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        sshPath: String = "/usr/bin/ssh",
        sshAgentProbe: () -> SSHAgentStatus = querySSHAgent
    ) -> DoctorReport {
        var checks: [DoctorCheck] = []
        let fm = FileManager.default

        // 1. App reachability and socket permissions.
        let running = client.isRunning()
        let socketPath = client.socketURL.path
        let socketExists = fm.fileExists(atPath: socketPath)
        if running {
            if let attrs = try? fm.attributesOfItem(atPath: socketPath),
               let mode = attrs[.posixPermissions] as? Int {
                if mode == 0o600 {
                    checks.append(DoctorCheck(name: "app", level: .ok, detail: "Running; control socket \(socketPath) (0600)."))
                } else {
                    let octal = String(mode, radix: 8)
                    checks.append(DoctorCheck(name: "app", level: .warn, detail: "Running; control socket \(socketPath) has mode \(octal), expected 600."))
                }
            } else {
                checks.append(DoctorCheck(name: "app", level: .ok, detail: "Running; control socket \(socketPath)."))
            }
        } else if socketExists {
            checks.append(DoctorCheck(name: "app", level: .warn, detail: "Not running (stale socket at \(socketPath))."))
        } else {
            checks.append(DoctorCheck(name: "app", level: .warn, detail: "Not running (no socket at \(socketPath))."))
        }

        // 2. Agent setup status (CLI symlink and skill file).
        let setup = AgentSetup.status(appBundle: appBundle, home: home)
        if setup.isComplete {
            checks.append(DoctorCheck(name: "setup", level: .ok, detail: "CLI symlink (\(setup.cliLink.path)) and skill (\(setup.skillFile.path)) are up to date."))
        } else {
            var issues: [String] = []
            if !setup.cliInstalled {
                issues.append("CLI symlink missing at \(setup.cliLink.path)")
            } else if !setup.cliMatchesBundle {
                issues.append("CLI symlink points to a different bundle")
            }
            if !setup.skillInstalled {
                issues.append("skill missing at \(setup.skillFile.path)")
            } else if !setup.skillUpToDate {
                issues.append("skill differs from app bundle")
            }
            checks.append(DoctorCheck(name: "setup", level: .warn, detail: "\(issues.joined(separator: "; ")). Run 'labtunnel setup'."))
        }

        // 3. ~/.local/bin in PATH.
        let binPath = setup.cliLink.deletingLastPathComponent().standardizedFileURL.path
        let pathEntries = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).standardizedFileURL.path }
        if pathEntries.contains(binPath) {
            checks.append(DoctorCheck(name: "path", level: .ok, detail: "\(binPath) is in PATH."))
        } else {
            checks.append(DoctorCheck(name: "path", level: .warn, detail: "\(binPath) is not in PATH."))
        }

        // 4. /usr/bin/ssh and ssh-agent loaded key count (never output fingerprints or identities).
        if !fm.isExecutableFile(atPath: sshPath) {
            checks.append(DoctorCheck(name: "ssh", level: .fail, detail: "\(sshPath) is missing or not executable."))
        } else {
            switch sshAgentProbe() {
            case .loaded(let count):
                let noun = count == 1 ? "key" : "keys"
                checks.append(DoctorCheck(name: "ssh", level: .ok, detail: "\(sshPath) available; ssh-agent has \(count) \(noun) loaded."))
            case .noKeys:
                checks.append(DoctorCheck(name: "ssh", level: .warn, detail: "\(sshPath) available; ssh-agent has 0 keys loaded."))
            case .noAgent:
                checks.append(DoctorCheck(name: "ssh", level: .warn, detail: "\(sshPath) available; ssh-agent is not running or reachable."))
            case .error(let status):
                checks.append(DoctorCheck(name: "ssh", level: .warn, detail: "\(sshPath) available; ssh-add -l exited with status \(status)."))
            }
        }

        // 5. Active tunnels summary if app is running.
        if running {
            do {
                let list = try client.send(ControlRequest(command: "list"), timeoutSeconds: 2)
                if list.ok {
                    let total = list.tunnels.count
                    let connected = list.tunnels.filter { $0.state == "connected" }.count
                    let failed = list.tunnels.filter { $0.state == "failed" }.map(\.name)
                    let closed = list.tunnels.filter { $0.state == "connected" && $0.remote == "notListening" }.map(\.name)
                    if failed.isEmpty && closed.isEmpty {
                        checks.append(DoctorCheck(name: "tunnels", level: .ok, detail: "\(connected)/\(total) connected."))
                    } else {
                        var parts = ["\(connected)/\(total) connected"]
                        if !failed.isEmpty { parts.append("failed: \(failed.joined(separator: ", "))") }
                        if !closed.isEmpty { parts.append("remote closed: \(closed.joined(separator: ", "))") }
                        checks.append(DoctorCheck(name: "tunnels", level: .warn, detail: parts.joined(separator: "; ") + "."))
                    }
                } else {
                    checks.append(DoctorCheck(name: "tunnels", level: .warn, detail: list.error ?? "Could not list tunnels."))
                }
            } catch {
                checks.append(DoctorCheck(name: "tunnels", level: .warn, detail: "\(error)"))
            }
        }

        let healthy = !checks.contains { $0.level == .fail }
        return DoctorReport(ok: healthy, checks: checks)
    }

    static func runDoctor(
        json: Bool,
        client: ControlClient,
        appBundle: URL? = enclosingAppBundle(),
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        sshPath: String = "/usr/bin/ssh",
        sshAgentProbe: () -> SSHAgentStatus = querySSHAgent
    ) -> Int32 {
        let report = collectDoctorReport(
            client: client,
            appBundle: appBundle,
            home: home,
            environment: environment,
            sshPath: sshPath,
            sshAgentProbe: sshAgentProbe
        )
        if json {
            print(Rendering.jsonValue(report))
        } else {
            print(Rendering.doctor(report))
        }
        return report.ok ? ExitCode.ok : ExitCode.failure
    }

    private static func querySSHAgent() -> SSHAgentStatus {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-add")
        process.arguments = ["-l"]
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return .error(-1)
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        switch process.terminationStatus {
        case 0:
            let count = String(decoding: data, as: UTF8.self)
                .split(whereSeparator: \.isNewline)
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .count
            return .loaded(count)
        case 1:
            return .noKeys
        case 2:
            return .noAgent
        default:
            return .error(process.terminationStatus)
        }
    }

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

extension TunnelFields {
    /// Mirrors `Tunnel.sameConnection` in the app: the fields that restart a live tunnel.
    var changesConnection: Bool {
        host != nil || remoteHost != nil || remotePort != nil || localPort != nil || useFreePortIfBusy != nil
    }
}
