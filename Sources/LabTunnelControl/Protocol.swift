import Foundation

/// Fields of a tunnel that `add` and `update` can set. Nil means "not specified".
public struct TunnelFields: Codable, Equatable {
    public var name: String?
    public var host: String?
    public var remotePort: Int?
    public var localPort: Int?
    public var scheme: String?
    public var group: String?
    public var connectOnLaunch: Bool?
    public var useFreePortIfBusy: Bool?

    public init(name: String? = nil, host: String? = nil, remotePort: Int? = nil, localPort: Int? = nil,
                scheme: String? = nil, group: String? = nil, connectOnLaunch: Bool? = nil,
                useFreePortIfBusy: Bool? = nil) {
        self.name = name
        self.host = host
        self.remotePort = remotePort
        self.localPort = localPort
        self.scheme = scheme
        self.group = group
        self.connectOnLaunch = connectOnLaunch
        self.useFreePortIfBusy = useFreePortIfBusy
    }

    public var isEmpty: Bool { self == TunnelFields() }
}

/// One request line sent to the running app. Commands: ping, list, status, add, update,
/// remove, connect, disconnect.
public struct ControlRequest: Codable, Equatable {
    public var command: String
    /// Tunnel names or ids (or unique id prefixes).
    public var targets: [String]
    /// Restricts list/connect/disconnect/remove to one group.
    public var group: String?
    public var all: Bool
    public var fields: TunnelFields
    /// For `add`: connect right after creating.
    public var connect: Bool

    public init(command: String, targets: [String] = [], group: String? = nil, all: Bool = false,
                fields: TunnelFields = TunnelFields(), connect: Bool = false) {
        self.command = command
        self.targets = targets
        self.group = group
        self.all = all
        self.fields = fields
        self.connect = connect
    }
}

public struct TrafficStatus: Codable, Equatable {
    public var up: Int
    public var down: Int
    public var upRate: Double
    public var downRate: Double

    public init(up: Int = 0, down: Int = 0, upRate: Double = 0, downRate: Double = 0) {
        self.up = up
        self.down = down
        self.upRate = upRate
        self.downRate = downRate
    }
}

public struct TunnelStatus: Codable, Equatable {
    public var id: String
    public var name: String
    public var host: String
    public var remotePort: Int
    /// The configured local port. See `activeLocalPort` for the one actually in use.
    public var localPort: Int
    public var scheme: String
    public var group: String
    public var connectOnLaunch: Bool
    public var useFreePortIfBusy: Bool
    /// idle, connecting, connected, reconnecting or failed.
    public var state: String
    public var error: String?
    /// Set while the tunnel is active. Differs from `localPort` after a free-port fallback.
    public var activeLocalPort: Int?
    /// Set while connected and the scheme is http or https.
    public var url: String?
    /// unknown, listening or notListening. Only meaningful while connected.
    public var remote: String
    public var traffic: TrafficStatus

    public init(id: String, name: String, host: String, remotePort: Int, localPort: Int, scheme: String,
                group: String, connectOnLaunch: Bool, useFreePortIfBusy: Bool, state: String,
                error: String? = nil, activeLocalPort: Int? = nil, url: String? = nil,
                remote: String = "unknown", traffic: TrafficStatus = TrafficStatus()) {
        self.id = id
        self.name = name
        self.host = host
        self.remotePort = remotePort
        self.localPort = localPort
        self.scheme = scheme
        self.group = group
        self.connectOnLaunch = connectOnLaunch
        self.useFreePortIfBusy = useFreePortIfBusy
        self.state = state
        self.error = error
        self.activeLocalPort = activeLocalPort
        self.url = url
        self.remote = remote
        self.traffic = traffic
    }
}

public struct ControlResponse: Codable, Equatable {
    public var ok: Bool
    public var error: String?
    /// Machine-readable failure reason: usage, invalid, not_found, ambiguous, exists, internal.
    public var code: String?
    public var tunnels: [TunnelStatus]

    public init(ok: Bool, error: String? = nil, code: String? = nil, tunnels: [TunnelStatus] = []) {
        self.ok = ok
        self.error = error
        self.code = code
        self.tunnels = tunnels
    }

    public static func success(_ tunnels: [TunnelStatus] = []) -> ControlResponse {
        ControlResponse(ok: true, tunnels: tunnels)
    }

    public static func failure(_ code: String, _ message: String) -> ControlResponse {
        ControlResponse(ok: false, error: message, code: code)
    }
}

public enum ControlPaths {
    /// `~/Library/Application Support/LabTunnel/control.sock`. Sockets are limited to 104
    /// bytes of path, which this stays well under for normal home directories.
    public static var defaultSocketURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LabTunnel/control.sock")
    }

    public static let appBundleIdentifier = "dev.messerschmidt.labtunnel"
}
