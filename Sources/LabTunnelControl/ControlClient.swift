import Foundation

/// Sends one request to the running LabTunnel app and returns its answer.
public struct ControlClient {
    public enum Failure: Error, CustomStringConvertible {
        case unreachable(String)
        case badResponse(String)

        public var description: String {
            switch self {
            case .unreachable(let reason): "LabTunnel is not reachable: \(reason)"
            case .badResponse(let reason): "Unexpected reply from LabTunnel: \(reason)"
            }
        }
    }

    public let socketURL: URL

    public init(socketURL: URL = ControlPaths.defaultSocketURL) {
        self.socketURL = socketURL
    }

    public func send(_ request: ControlRequest, timeoutSeconds: Int = 10) throws -> ControlResponse {
        let fd: Int32
        do {
            fd = try UnixSocket.connect(path: socketURL.path, timeoutSeconds: timeoutSeconds)
        } catch {
            throw Failure.unreachable("\(error)")
        }
        defer { close(fd) }

        UnixSocket.writeLine(fd, try JSONEncoder().encode(request))
        guard let line = UnixSocket.readLine(fd) else { throw Failure.badResponse("no reply") }
        do {
            return try JSONDecoder().decode(ControlResponse.self, from: line)
        } catch {
            throw Failure.badResponse("\(error)")
        }
    }

    public func isRunning() -> Bool {
        (try? send(ControlRequest(command: "ping"), timeoutSeconds: 2))?.ok == true
    }
}
