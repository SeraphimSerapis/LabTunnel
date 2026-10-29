import Foundation
import LabTunnelControl

/// Serves the control protocol on a Unix socket so the CLI and agents can drive the app.
/// The socket is `0600` inside the user's Application Support folder, so only this user
/// can connect.
@MainActor
final class ControlServer {
    enum Failure: Error, CustomStringConvertible {
        case alreadyRunning
        var description: String { "another LabTunnel instance already serves this socket" }
    }

    private let handler: ControlHandler
    private let socketURL: URL
    private var listenSource: DispatchSourceRead?

    init(manager: TunnelManager, socketURL: URL = ControlPaths.defaultSocketURL) {
        handler = ControlHandler(manager: manager)
        self.socketURL = socketURL
    }

    func start() throws {
        // Don't steal the socket from a live instance. A stale file from a crash is replaced.
        if ControlClient(socketURL: socketURL).isRunning() { throw Failure.alreadyRunning }
        try FileManager.default.createDirectory(
            at: socketURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = try UnixSocket.listen(path: socketURL.path)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global())
        source.setEventHandler { [weak self] in
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            UnixSocket.configure(client, timeoutSeconds: 3)
            Task.detached { await self?.serve(client) }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        listenSource = source
    }

    func stop() {
        listenSource?.cancel()
        listenSource = nil
        unlink(socketURL.path)
    }

    private nonisolated func serve(_ client: Int32) async {
        defer { close(client) }
        guard let line = UnixSocket.readLine(client) else { return }

        let response: ControlResponse
        if let request = try? JSONDecoder().decode(ControlRequest.self, from: line) {
            response = await MainActor.run { handler.handle(request) }
        } else {
            response = .failure("usage", "Request is not valid JSON for this protocol.")
        }
        if let payload = try? JSONEncoder().encode(response) { UnixSocket.writeLine(client, payload) }
    }
}
