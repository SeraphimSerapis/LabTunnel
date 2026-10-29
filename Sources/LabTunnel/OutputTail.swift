import Foundation

/// Drains a child process's output pipe as data arrives and keeps only the last `limit` bytes.
///
/// A pipe buffers 64 KB. A child whose pipe nobody reads blocks on its next write once that
/// buffer fills. `ssh` logs a line for every forwarded connection the remote side refuses,
/// so a tunnel pointed at a stopped service froze after roughly a thousand attempts while
/// still showing as connected. Reading continuously prevents that, and the size cap keeps
/// memory flat for a tunnel that runs for weeks.
final class OutputTail: @unchecked Sendable {
    /// Hand this to `Process.standardError` (or `standardOutput`) before `run()`.
    let pipe = Pipe()
    private let limit: Int
    private let lock = NSLock()
    private var buffer = Data()
    private let closed = DispatchSemaphore(value: 0)

    init(limit: Int = 8192) {
        self.limit = limit
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self, !chunk.isEmpty else {
                handle.readabilityHandler = nil
                self?.closed.signal()
                return
            }
            self.append(chunk)
        }
    }

    private func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(chunk)
        if buffer.count > limit { buffer = Data(buffer.suffix(limit)) }
    }

    /// Waits until every writer has closed the pipe, then returns what was kept.
    /// The timeout covers a grandchild, such as a `ProxyCommand`, that inherited the pipe and
    /// outlives the process we started.
    func text(waitingUpTo timeout: DispatchTimeInterval = .seconds(2)) -> String {
        _ = closed.wait(timeout: .now() + timeout)
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: buffer, as: UTF8.self)
    }
}
