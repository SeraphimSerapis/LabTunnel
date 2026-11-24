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
    private let controlQueue = DispatchQueue(label: "dev.messerschmidt.labtunnel.control", attributes: .concurrent)
    private var listenSource: DispatchSourceRead?

    init(manager: TunnelManager, socketURL: URL = ControlPaths.defaultSocketURL) {
        handler = ControlHandler(manager: manager)
        self.socketURL = socketURL
    }

    func start() throws {
        // Don't steal the socket from a live instance. A stale file from a crash is replaced.
        if ControlClient(socketURL: socketURL).isRunning() { throw Failure.alreadyRunning }
        let directory = socketURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let standardizedDir = directory.standardizedFileURL.path
        let resolvedDir = directory.resolvingSymlinksInPath().path
        if standardizedDir != "/tmp" && standardizedDir != "/private/tmp" && resolvedDir != "/private/tmp" {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
        let fd = try UnixSocket.listen(path: socketURL.path)

        let queue = controlQueue
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            UnixSocket.configure(client, timeoutSeconds: 3)
            queue.async { [weak self] in
                guard let self else {
                    close(client)
                    return
                }
                self.serve(client)
            }
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

    private nonisolated func serve(_ client: Int32) {
        guard let line = UnixSocket.readLine(client) else {
            close(client)
            return
        }

        guard let request = try? JSONDecoder().decode(ControlRequest.self, from: line) else {
            let response = ControlResponse.failure("usage", "Request is not valid JSON for this protocol.")
            if let payload = try? JSONEncoder().encode(response) {
                UnixSocket.writeLine(client, payload)
            }
            close(client)
            return
        }

        let queue = controlQueue
        Task { @MainActor [weak self] in
            let response: ControlResponse
            if let self {
                if request.command == "wait" {
                    response = await self.handleWait(request)
                } else {
                    response = self.handler.handle(request)
                }
            } else {
                response = .failure("internal", "Server stopped.")
            }
            let payload = try? JSONEncoder().encode(response)
            queue.async {
                defer { close(client) }
                if let payload {
                    UnixSocket.writeLine(client, payload)
                }
            }
        }
    }

    private func handleWait(_ request: ControlRequest) async -> ControlResponse {
        do {
            let ids = try handler.resolvedIDs(for: request)
            let timeout = max(0.0, request.timeout ?? 20.0)
            let timedOut = await handler.manager.waitForSettlement(ids: ids, timeout: timeout)
            let freshStatuses = handler.statuses(for: ids)
            return ControlResponse(
                ok: true,
                error: timedOut ? "Timed out waiting for the tunnel to connect." : nil,
                code: timedOut ? "timeout" : nil,
                tunnels: freshStatuses
            )
        } catch {
            return handler.errorResponse(for: error)
        }
    }
}
