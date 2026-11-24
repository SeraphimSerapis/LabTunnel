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
    private let onLine: (@Sendable (String) -> Void)?
    private let lock = NSLock()
    private var buffer = Data()
    private var lineBuffer = Data()
    private var isClosed = false
    private let closed = DispatchSemaphore(value: 0)

    init(limit: Int = 8192, onLine: (@Sendable (String) -> Void)? = nil) {
        self.limit = max(0, limit)
        self.onLine = onLine
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self else {
                handle.readabilityHandler = nil
                return
            }
            if chunk.isEmpty {
                self.close()
                return
            }
            self.append(chunk)
        }
    }

    private func append(_ chunk: Data) {
        var linesToEmit: [String] = []
        lock.lock()
        buffer.append(chunk)
        if buffer.count > limit * 2 {
            buffer = Data(buffer.suffix(limit))
        }
        if onLine != nil {
            lineBuffer.append(chunk)
            var searchStart = lineBuffer.startIndex
            while let newlineIndex = lineBuffer[searchStart...].firstIndex(of: 0x0A) {
                var lineEnd = newlineIndex
                if lineEnd > searchStart && lineBuffer[lineBuffer.index(before: lineEnd)] == 0x0D {
                    lineEnd = lineBuffer.index(before: lineEnd)
                }
                linesToEmit.append(String(decoding: lineBuffer[searchStart..<lineEnd], as: UTF8.self))
                searchStart = lineBuffer.index(after: newlineIndex)
            }
            if searchStart > lineBuffer.startIndex {
                lineBuffer.removeSubrange(lineBuffer.startIndex..<searchStart)
            }
            if lineBuffer.count > limit {
                lineBuffer = Data(lineBuffer.suffix(limit))
            }
        }
        lock.unlock()

        if let onLine {
            for line in linesToEmit {
                onLine(line)
            }
        }
    }

    /// Stops draining the pipe and unblocks any `text(waitingUpTo:)` caller. Idempotent.
    func close() {
        lock.lock()
        let shouldSignal = !isClosed
        if shouldSignal {
            isClosed = true
        }
        lock.unlock()
        pipe.fileHandleForReading.readabilityHandler = nil
        if shouldSignal {
            closed.signal()
        }
    }

    /// Waits until every writer has closed the pipe, then returns what was kept.
    /// The timeout covers a grandchild, such as a `ProxyCommand`, that inherited the pipe and
    /// outlives the process we started.
    func text(waitingUpTo timeout: DispatchTimeInterval = .seconds(2)) -> String {
        if closed.wait(timeout: .now() + timeout) == .timedOut {
            close()
        }
        lock.lock()
        let slice = Data(buffer.suffix(limit))
        lock.unlock()
        return String(decoding: slice, as: UTF8.self)
    }

    /// Picks the most informative error line from `ssh` stderr, skipping empty lines and pure `@` banners.
    static func extractError(from stderr: String) -> String? {
        let trimSet = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\r"))
        let lines = stderr.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: trimSet) }
            .filter { !$0.isEmpty && !$0.allSatisfy { $0 == "@" } }
        guard let last = lines.last else { return nil }

        let genericEndings: Set<String> = [
            "Could not request local forwarding.",
            "Connection closed.",
        ]
        if genericEndings.contains(last) {
            let specificCauses = [
                "Address already in use",
                "Permission denied",
                "Host key verification failed",
                "Could not resolve hostname",
                "Connection refused",
                "Connection timed out",
            ]
            if let specific = lines.dropLast().last(where: { line in
                specificCauses.contains { line.contains($0) }
            }) {
                return specific
            }
        }
        return last
    }
}
