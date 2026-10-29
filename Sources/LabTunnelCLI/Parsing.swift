import Foundation
import LabTunnelControl

struct UsageError: Error, Equatable {
    let message: String
}

struct Options: Equatable {
    var json = false
    /// For `connect`: block until each tunnel is up or has failed.
    var wait = true
    var timeout = 20.0
}

enum Invocation: Equatable {
    case help
    case setup
    case request(ControlRequest, Options)
}

enum Parsing {
    static let commands = ["list", "status", "add", "update", "remove", "connect", "disconnect"]

    /// Flags that take a value, and flags that don't. `--no-<flag>` negates the boolean ones.
    private static let fieldFlags: Set<String> = [
        "name", "host", "remote-port", "local-port", "scheme",
        "connect-on-launch", "no-connect-on-launch", "free-port", "no-free-port",
    ]

    static func parse(_ arguments: [String]) throws -> Invocation {
        var args = arguments[...]
        guard let command = args.popFirst() else { return .help }
        if ["help", "-h", "--help"].contains(command) { return .help }
        if command == "setup" { return .setup }
        guard commands.contains(command) else { throw UsageError(message: "Unknown command '\(command)'.") }

        var request = ControlRequest(command: command)
        var options = Options()
        var positionals: [String] = []
        var group: String?
        var usedFieldFlag: String?

        while let arg = args.popFirst() {
            guard arg.hasPrefix("--") else {
                positionals.append(arg)
                continue
            }
            var name = String(arg.dropFirst(2))
            var inlineValue: String?
            if let equals = name.firstIndex(of: "=") {
                inlineValue = String(name[name.index(after: equals)...])
                name = String(name[..<equals])
            }
            func value() throws -> String {
                if let inlineValue { return inlineValue }
                guard let next = args.popFirst() else { throw UsageError(message: "--\(name) needs a value.") }
                return next
            }
            func port() throws -> Int {
                let raw = try value()
                guard let number = Int(raw), (1...65535).contains(number) else {
                    throw UsageError(message: "--\(name) must be a port between 1 and 65535, got '\(raw)'.")
                }
                return number
            }

            if fieldFlags.contains(name) { usedFieldFlag = usedFieldFlag ?? name }
            switch name {
            case "json": options.json = true
            case "all": request.all = true
            case "no-wait": options.wait = false
            case "connect": request.connect = true
            case "group": group = try value()
            case "timeout":
                let raw = try value()
                guard let seconds = Double(raw), seconds > 0 else {
                    throw UsageError(message: "--timeout must be a positive number of seconds.")
                }
                options.timeout = seconds
            case "name": request.fields.name = try value()
            case "host": request.fields.host = try value()
            case "remote-port": request.fields.remotePort = try port()
            case "local-port": request.fields.localPort = try port()
            case "scheme":
                let raw = try value().lowercased()
                guard ["http", "https", "tcp"].contains(raw) else {
                    throw UsageError(message: "--scheme must be http, https or tcp.")
                }
                request.fields.scheme = raw
            case "connect-on-launch": request.fields.connectOnLaunch = true
            case "no-connect-on-launch": request.fields.connectOnLaunch = false
            case "free-port": request.fields.useFreePortIfBusy = true
            case "no-free-port": request.fields.useFreePortIfBusy = false
            default: throw UsageError(message: "Unknown option --\(name).")
            }
        }

        let editsFields = command == "add" || command == "update"
        if let flag = usedFieldFlag, !editsFields {
            throw UsageError(message: "--\(flag) only applies to add and update.")
        }
        if request.connect && command != "add" {
            throw UsageError(message: "--connect only applies to add. Use the connect command instead.")
        }
        if editsFields {
            request.fields.group = group  // here --group sets the tunnel's group
        } else {
            request.group = group  // elsewhere it filters
        }

        switch command {
        case "add":
            guard positionals.isEmpty else { throw UsageError(message: "add takes options only, got '\(positionals[0])'.") }
            guard request.fields.name != nil, request.fields.host != nil, request.fields.remotePort != nil else {
                throw UsageError(message: "add needs --name, --host and --remote-port.")
            }
        case "update":
            guard positionals.count == 1 else { throw UsageError(message: "update needs exactly one tunnel name or id.") }
            guard !request.fields.isEmpty else { throw UsageError(message: "update needs at least one option to change.") }
            request.targets = positionals
        case "remove":
            guard !positionals.isEmpty else { throw UsageError(message: "remove needs at least one tunnel name or id.") }
            request.targets = positionals
        case "connect", "disconnect":
            guard !positionals.isEmpty || request.group != nil || request.all else {
                throw UsageError(message: "\(command) needs a tunnel name, --group or --all.")
            }
            request.targets = positionals
        default:  // list, status
            request.targets = positionals
        }
        return .request(request, options)
    }
}
