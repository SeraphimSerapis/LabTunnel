import Foundation
import LabTunnelControl

/// Executes control requests against the tunnel manager. Kept free of sockets so it can be
/// tested directly.
@MainActor
struct ControlHandler {
    let manager: TunnelManager

    private struct Failure: Error {
        let code: String
        let message: String
    }

    func handle(_ request: ControlRequest) -> ControlResponse {
        do {
            return .success(try run(request))
        } catch let failure as Failure {
            return .failure(failure.code, failure.message)
        } catch {
            return .failure("internal", "\(error)")
        }
    }

    private func run(_ request: ControlRequest) throws -> [TunnelStatus] {
        switch request.command {
        case "ping":
            return []
        case "list", "status":
            return try selection(request, allowEmpty: true).map(status)
        case "add":
            return [status(try add(request))]
        case "update":
            return [status(try update(request))]
        case "remove":
            let targets = try selection(request, allowEmpty: false)
            let before = targets.map(status)
            targets.forEach(manager.delete)
            return before
        case "connect":
            let targets = try selection(request, allowEmpty: false)
            targets.forEach(manager.connect)
            return targets.map(status)
        case "disconnect":
            let targets = try selection(request, allowEmpty: false)
            targets.forEach(manager.disconnect)
            return targets.map(status)
        default:
            throw Failure(code: "usage", message: "Unknown command '\(request.command)'.")
        }
    }

    // MARK: Commands

    private func add(_ request: ControlRequest) throws -> Tunnel {
        let fields = request.fields
        guard let name = fields.name, let host = fields.host, let remotePort = fields.remotePort else {
            throw Failure(code: "usage", message: "add needs a name, a host and a remote port.")
        }
        // An empty local port means "same as remote", as in the editor.
        let localPort = fields.localPort ?? remotePort
        try validate(name: name, host: host, remotePort: remotePort, localPort: localPort)
        try ensureNameIsFree(name, except: nil)

        let tunnel = Tunnel(
            name: name.trimmed, host: host.trimmed, remotePort: remotePort, localPort: localPort,
            scheme: try scheme(fields.scheme) ?? .http, group: fields.group?.trimmed ?? "",
            connectOnLaunch: fields.connectOnLaunch ?? false,
            useFreePortIfBusy: fields.useFreePortIfBusy ?? false
        )
        manager.save(tunnel)
        if request.connect { manager.connect(tunnel) }
        return tunnel
    }

    private func update(_ request: ControlRequest) throws -> Tunnel {
        guard request.targets.count == 1 else {
            throw Failure(code: "usage", message: "update needs exactly one tunnel.")
        }
        guard !request.fields.isEmpty else {
            throw Failure(code: "usage", message: "update needs at least one field to change.")
        }
        let original = try resolve(request.targets[0])
        let fields = request.fields
        var updated = original
        if let name = fields.name { updated.name = name.trimmed }
        if let host = fields.host { updated.host = host.trimmed }
        if let port = fields.remotePort { updated.remotePort = port }
        if let port = fields.localPort { updated.localPort = port }
        if let value = try scheme(fields.scheme) { updated.scheme = value }
        if let group = fields.group { updated.group = group.trimmed }
        if let value = fields.connectOnLaunch { updated.connectOnLaunch = value }
        if let value = fields.useFreePortIfBusy { updated.useFreePortIfBusy = value }

        try validate(name: updated.name, host: updated.host, remotePort: updated.remotePort, localPort: updated.localPort)
        try ensureNameIsFree(updated.name, except: original.id)

        manager.save(updated)  // reconnects a live tunnel whose connection settings changed
        return updated
    }

    // MARK: Helpers

    /// Tunnels named by the request: explicit targets, a group, or everything.
    private func selection(_ request: ControlRequest, allowEmpty: Bool) throws -> [Tunnel] {
        if !request.targets.isEmpty {
            var seen = Set<UUID>()
            return try request.targets.map(resolve).filter { seen.insert($0.id).inserted }
        }
        if let group = request.group {
            let members = manager.tunnels.filter { $0.group.caseInsensitiveCompare(group) == .orderedSame }
            if members.isEmpty && !allowEmpty { throw Failure(code: "not_found", message: "No tunnels in group '\(group)'.") }
            return members
        }
        if request.all || allowEmpty { return manager.tunnels }
        throw Failure(code: "usage", message: "\(request.command) needs a tunnel name, --group or --all.")
    }

    /// Matches an exact id, an exact name (case-insensitive), or a unique id prefix.
    private func resolve(_ token: String) throws -> Tunnel {
        let wanted = token.lowercased()
        if let byID = manager.tunnels.first(where: { $0.id.uuidString.lowercased() == wanted }) { return byID }

        let byName = manager.tunnels.filter { $0.name.lowercased() == wanted }
        if byName.count == 1 { return byName[0] }
        if byName.count > 1 { throw ambiguous(token, byName) }

        if wanted.count >= 4 {
            let byPrefix = manager.tunnels.filter { $0.id.uuidString.lowercased().hasPrefix(wanted) }
            if byPrefix.count == 1 { return byPrefix[0] }
            if byPrefix.count > 1 { throw ambiguous(token, byPrefix) }
        }
        throw Failure(code: "not_found", message: "No tunnel named or with id '\(token)'.")
    }

    private func ambiguous(_ token: String, _ matches: [Tunnel]) -> Failure {
        let ids = matches.map { "\($0.name) (\($0.id.uuidString))" }.joined(separator: ", ")
        return Failure(code: "ambiguous", message: "'\(token)' matches several tunnels: \(ids). Use an id.")
    }

    private func validate(name: String, host: String, remotePort: Int, localPort: Int) throws {
        if let problem = Tunnel.validate(name: name, host: host, remotePort: remotePort, localPort: localPort) {
            throw Failure(code: "invalid", message: problem)
        }
    }

    private func ensureNameIsFree(_ name: String, except id: UUID?) throws {
        if manager.isNameTaken(name, except: id) {
            throw Failure(code: "exists", message: "A tunnel named '\(name.trimmed)' already exists.")
        }
    }

    private func scheme(_ raw: String?) throws -> Scheme? {
        guard let raw else { return nil }
        guard let scheme = Scheme(rawValue: raw.lowercased()) else {
            throw Failure(code: "invalid", message: "Scheme must be http, https or tcp.")
        }
        return scheme
    }

    func status(_ tunnel: Tunnel) -> TunnelStatus {
        let state = manager.state(of: tunnel)
        let port = manager.localPort(of: tunnel)
        let traffic = manager.traffic[tunnel.id] ?? Traffic()

        let stateName: String
        var error: String?
        switch state {
        case .idle: stateName = "idle"
        case .connecting: stateName = "connecting"
        case .connected: stateName = "connected"
        case .reconnecting: stateName = "reconnecting"
        case .failed(let message):
            stateName = "failed"
            error = message
        }
        let remote: String
        switch manager.remoteStatus(of: tunnel) {
        case .unknown: remote = "unknown"
        case .listening: remote = "listening"
        case .notListening: remote = "notListening"
        }

        return TunnelStatus(
            id: tunnel.id.uuidString, name: tunnel.name, host: tunnel.host,
            remotePort: tunnel.remotePort, localPort: tunnel.localPort, scheme: tunnel.scheme.rawValue,
            group: tunnel.group, connectOnLaunch: tunnel.connectOnLaunch,
            useFreePortIfBusy: tunnel.useFreePortIfBusy, state: stateName, error: error,
            activeLocalPort: state.isActive ? port : nil,
            url: state == .connected ? tunnel.url(localPort: port)?.absoluteString : nil,
            remote: remote,
            traffic: TrafficStatus(up: traffic.up, down: traffic.down,
                                   upRate: traffic.upRate, downRate: traffic.downRate)
        )
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespaces) }
}
