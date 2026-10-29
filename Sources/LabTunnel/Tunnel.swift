import Foundation

/// What the forwarded port speaks. Decides whether "Open in Browser" makes sense.
enum Scheme: String, Codable, CaseIterable, Identifiable {
    case http, https, tcp

    var id: String { rawValue }
    var label: String { rawValue == "tcp" ? "TCP" : rawValue.uppercased() }
}

/// One saved forward: `localhost:localPort` -> `host`'s `127.0.0.1:remotePort`.
/// The same host can appear in many entries with different ports.
struct Tunnel: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    /// Anything `ssh` accepts as a destination: a ~/.ssh/config alias, hostname, or user@host.
    var host: String
    var remotePort: Int
    var localPort: Int
    var scheme: Scheme = .http
    /// Entries with the same non-empty group are listed together and can be toggled as one.
    var group: String = ""
    var connectOnLaunch = false
    /// When the local port is taken, use the next free one instead of failing.
    /// Leave off for OAuth-style flows where the redirect URI pins the port.
    var useFreePortIfBusy = false

    /// Where a browser should go, or nil for plain TCP services.
    func url(localPort: Int) -> URL? {
        scheme == .tcp ? nil : URL(string: "\(scheme.rawValue)://127.0.0.1:\(localPort)")
    }

    /// "host:3000 → localhost:3001". Built as a plain String on purpose: handing an Int to a
    /// SwiftUI `Text` interpolation applies locale grouping, and 5173 becomes "5.173" in German.
    func route(localPort: Int) -> String {
        "\(host):\(remotePort) → localhost:\(localPort)"
    }

    /// True if a running `ssh` for `other` would behave identically to one for `self`.
    /// Renaming, regrouping or changing the scheme must not drop a live tunnel.
    func sameConnection(as other: Tunnel) -> Bool {
        host == other.host && remotePort == other.remotePort
            && localPort == other.localPort && useFreePortIfBusy == other.useFreePortIfBusy
    }

    /// Arguments for `/usr/bin/ssh`. Key-based auth only (BatchMode), and the tunnel
    /// exits on its own if the forward can't be bound or the link goes quiet.
    /// Multiplexing is disabled: with a ControlMaster in ~/.ssh/config, ssh hands the
    /// forward to the shared master and exits, leaving us nothing to stop.
    func sshArguments(localPort: Int) -> [String] {
        [
            "-N",
            "-o", "BatchMode=yes",
            "-o", "ControlMaster=no",
            "-o", "ControlPath=none",
            "-o", "ConnectTimeout=10",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-L", "127.0.0.1:\(localPort):127.0.0.1:\(remotePort)",
            "--", host,
        ]
    }

    /// Returns a user-facing problem description, or nil if the entry is usable.
    static func validate(name: String, host: String, remotePort: Int?, localPort: Int?) -> String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return "Name is required." }
        let host = host.trimmingCharacters(in: .whitespaces)
        if host.isEmpty { return "Host is required." }
        // A leading dash would be parsed by ssh as an option.
        if host.hasPrefix("-") || host.contains(where: \.isWhitespace) { return "Host is not a valid SSH destination." }
        guard let remotePort, (1...65535).contains(remotePort) else { return "Remote port must be 1-65535." }
        guard let localPort, (1...65535).contains(localPort) else { return "Local port must be 1-65535." }
        return nil
    }
}

// Decoding lives in an extension so the memberwise initializer survives.
// Fields added after the first release default when missing from saved JSON.
extension Tunnel {
    private enum CodingKeys: String, CodingKey {
        case id, name, host, remotePort, localPort, scheme, group, connectOnLaunch, useFreePortIfBusy
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        host = try c.decode(String.self, forKey: .host)
        remotePort = try c.decode(Int.self, forKey: .remotePort)
        localPort = try c.decode(Int.self, forKey: .localPort)
        scheme = try c.decodeIfPresent(Scheme.self, forKey: .scheme) ?? .http
        group = try c.decodeIfPresent(String.self, forKey: .group) ?? ""
        connectOnLaunch = try c.decodeIfPresent(Bool.self, forKey: .connectOnLaunch) ?? false
        useFreePortIfBusy = try c.decodeIfPresent(Bool.self, forKey: .useFreePortIfBusy) ?? false
    }
}

enum TunnelState: Equatable {
    case idle
    case connecting
    case connected
    /// The link dropped after it was up; retrying with backoff until the user switches it off.
    case reconnecting
    case failed(String)

    var isActive: Bool {
        switch self {
        case .connecting, .connected, .reconnecting: true
        case .idle, .failed: false
        }
    }
}

/// Whether anything answers behind a connected tunnel.
enum RemoteStatus {
    case unknown, listening, notListening
}

struct TunnelSection: Identifiable {
    /// Empty for entries without a group.
    let name: String
    let tunnels: [Tunnel]
    var id: String { name }
}
