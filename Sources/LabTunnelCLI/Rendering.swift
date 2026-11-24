import Foundation
import LabTunnelControl

enum CheckLevel: String, Encodable, Equatable {
    case ok
    case warn
    case fail
}

struct DoctorCheck: Encodable, Equatable {
    let name: String
    let level: CheckLevel
    let detail: String
}

struct DoctorReport: Encodable, Equatable {
    let ok: Bool
    let checks: [DoctorCheck]
}

struct VersionReport: Encodable, Equatable {
    let ok: Bool
    let version: String
    let appVersion: String?
}

enum Rendering {
    private static let byteFormatterLock = NSLock()
    private static nonisolated(unsafe) let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter
    }()

    static func json(_ response: ControlResponse) -> String {
        jsonValue(response)
    }

    static func jsonValue<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: (try? encoder.encode(value)) ?? Data(), as: UTF8.self)
    }

    static func bytes(_ count: Int) -> String {
        if count < 1024 { return "\(count) B" }
        byteFormatterLock.lock()
        defer { byteFormatterLock.unlock() }
        return byteFormatter.string(fromByteCount: Int64(count))
    }

    static func uptime(_ seconds: Int) -> String {
        let clamped = max(0, seconds)
        let days = clamped / 86_400
        let hours = (clamped % 86_400) / 3_600
        let minutes = (clamped % 3_600) / 60
        let secs = clamped % 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m \(secs)s" }
        return "\(secs)s"
    }

    static func remoteTarget(_ tunnel: TunnelStatus) -> String {
        if let remoteHost = tunnel.remoteHost, !remoteHost.isEmpty, remoteHost != "127.0.0.1" {
            return "\(tunnel.host) -> \(remoteHost):\(tunnel.remotePort)"
        }
        return "\(tunnel.host):\(tunnel.remotePort)"
    }

    /// Where the tunnel can be reached right now, or the configured port when it is off.
    static func local(_ tunnel: TunnelStatus) -> String {
        "127.0.0.1:\(tunnel.activeLocalPort ?? tunnel.localPort)"
    }

    static func stateText(_ tunnel: TunnelStatus) -> String {
        if tunnel.state == "connected" && tunnel.remote == "notListening" { return "connected (remote port closed)" }
        if let error = tunnel.error, tunnel.state == "failed" { return "failed: \(error)" }
        return tunnel.state
    }

    /// A left-aligned table, or a hint when empty.
    static func table(_ tunnels: [TunnelStatus]) -> String {
        guard !tunnels.isEmpty else { return "No tunnels." }
        let header = ["NAME", "TARGET", "LOCAL", "TYPE", "GROUP", "STATE"]
        let rows = tunnels.map {
            [$0.name, remoteTarget($0), local($0), $0.scheme, $0.group.isEmpty ? "-" : $0.group, stateText($0)]
        }
        let widths = header.indices.map { column in ([header] + rows).map { $0[column].count }.max()! }
        return ([header] + rows).map { row in
            zip(row, widths).map { $0.padding(toLength: $1, withPad: " ", startingAt: 0) }
                .joined(separator: "  ").trimmingCharacters(in: .whitespaces)
        }.joined(separator: "\n")
    }

    /// Key-value detail for a single tunnel.
    static func detail(_ tunnel: TunnelStatus) -> String {
        var lines = [
            "name:      \(tunnel.name)",
            "id:        \(tunnel.id)",
            "target:    \(remoteTarget(tunnel))",
            "local:     \(local(tunnel))",
            "type:      \(tunnel.scheme)",
            "group:     \(tunnel.group.isEmpty ? "-" : tunnel.group)",
            "state:     \(stateText(tunnel))",
        ]
        if let url = tunnel.url { lines.append("url:       \(url)") }
        if tunnel.state == "connected" {
            lines.append("remote:    \(tunnel.remote)")
            if let uptimeSeconds = tunnel.uptimeSeconds {
                lines.append("uptime:    \(uptime(uptimeSeconds))")
            }
            let upText: String
            let downText: String
            if tunnel.traffic.upRate >= 1 || tunnel.traffic.downRate >= 1 {
                upText = "\(bytes(tunnel.traffic.up)) (\(bytes(Int(tunnel.traffic.upRate)))/s)"
                downText = "\(bytes(tunnel.traffic.down)) (\(bytes(Int(tunnel.traffic.downRate)))/s)"
            } else {
                upText = bytes(tunnel.traffic.up)
                downText = bytes(tunnel.traffic.down)
            }
            lines.append("traffic:   up \(upText), down \(downText)")
        }
        return lines.joined(separator: "\n")
    }

    /// One line per tunnel after a change: "added s1ui (host:5173 -> 127.0.0.1:5173)".
    static func summary(verb: String, _ tunnel: TunnelStatus) -> String {
        "\(verb) \(tunnel.name) (\(remoteTarget(tunnel)) -> \(local(tunnel)))"
    }

    static func connectResult(_ tunnel: TunnelStatus) -> String {
        switch tunnel.state {
        case "connected":
            return "connected \(tunnel.name) \(tunnel.url ?? local(tunnel))"
                + (tunnel.remote == "notListening" ? " (warning: nothing is listening on the remote port)" : "")
        case "failed":
            return "failed \(tunnel.name): \(tunnel.error ?? "unknown error")"
        default:
            return "\(tunnel.state) \(tunnel.name)"
        }
    }

    static func hosts(_ hosts: [String]) -> String {
        guard !hosts.isEmpty else { return "No hosts found in ~/.ssh/config." }
        return hosts.joined(separator: "\n")
    }

    static func doctor(_ report: DoctorReport) -> String {
        report.checks.map { check in
            "[\(check.level.rawValue)] \(check.name): \(check.detail)"
        }.joined(separator: "\n")
    }
}
