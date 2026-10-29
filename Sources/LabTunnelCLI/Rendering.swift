import Foundation
import LabTunnelControl

enum Rendering {
    static func json(_ response: ControlResponse) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: (try? encoder.encode(response)) ?? Data(), as: UTF8.self)
    }

    static func bytes(_ count: Int) -> String {
        if count < 1024 { return "\(count) B" }
        return ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .binary)
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
        let header = ["NAME", "HOST:PORT", "LOCAL", "TYPE", "GROUP", "STATE"]
        let rows = tunnels.map {
            [$0.name, "\($0.host):\($0.remotePort)", local($0), $0.scheme, $0.group.isEmpty ? "-" : $0.group, stateText($0)]
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
            "target:    \(tunnel.host):\(tunnel.remotePort)",
            "local:     \(local(tunnel))",
            "type:      \(tunnel.scheme)",
            "group:     \(tunnel.group.isEmpty ? "-" : tunnel.group)",
            "state:     \(stateText(tunnel))",
        ]
        if let url = tunnel.url { lines.append("url:       \(url)") }
        if tunnel.state == "connected" {
            lines.append("remote:    \(tunnel.remote)")
            lines.append("traffic:   up \(bytes(tunnel.traffic.up)), down \(bytes(tunnel.traffic.down))")
        }
        return lines.joined(separator: "\n")
    }

    /// One line per tunnel after a change: "added s1ui (host:5173 -> 127.0.0.1:5173)".
    static func summary(verb: String, _ tunnel: TunnelStatus) -> String {
        "\(verb) \(tunnel.name) (\(tunnel.host):\(tunnel.remotePort) -> \(local(tunnel)))"
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
}
