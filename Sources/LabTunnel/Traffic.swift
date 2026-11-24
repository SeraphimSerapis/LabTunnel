import Darwin
import Foundation

/// Payload bytes through one tunnel, from the user's side: `up` is what local clients sent
/// into the forward, `down` is what came back. SSH framing and encryption overhead is excluded.
struct Traffic: Equatable {
    var up = 0
    var down = 0
    /// Bytes per second over the last sampling interval.
    var upRate = 0.0
    var downRate = 0.0
}

/// Turns the monitor's per-process cumulative counters into running totals and rates.
/// Totals carry across ssh restarts, because the counters start over with each new process.
struct TrafficCounter {
    private enum SampleClock {
        case wall(Date)
        case monotonic(TimeInterval)
    }

    private var carried = (up: 0, down: 0)
    private var last: (clock: SampleClock, up: Int, down: Int)?
    private(set) var current = Traffic()

    mutating func sample(up: Int, down: Int, at time: Date = Date()) {
        var rates = (up: 0.0, down: 0.0)
        if let last, case .wall(let prevTime) = last.clock, time > prevTime {
            let seconds = time.timeIntervalSince(prevTime)
            rates = (max(0, Double(up - last.up) / seconds), max(0, Double(down - last.down) / seconds))
        }
        last = (.wall(time), up, down)
        current = Traffic(up: carried.up + up, down: carried.down + down, upRate: rates.up, downRate: rates.down)
    }

    mutating func sample(up: Int, down: Int, monotonicSeconds: TimeInterval) {
        var rates = (up: 0.0, down: 0.0)
        if let last, case .monotonic(let prevSeconds) = last.clock, monotonicSeconds > prevSeconds {
            let seconds = monotonicSeconds - prevSeconds
            rates = (max(0, Double(up - last.up) / seconds), max(0, Double(down - last.down) / seconds))
        }
        last = (.monotonic(monotonicSeconds), up, down)
        current = Traffic(up: carried.up + up, down: carried.down + down, upRate: rates.up, downRate: rates.down)
    }

    /// The current ssh process ended: keep its bytes in the totals and stop reporting a rate.
    mutating func endSession() {
        if let last { carried = (carried.up + last.up, carried.down + last.down) }
        last = nil
        current.upRate = 0
        current.downRate = 0
    }
}

enum TrafficFormat {
    private static let formatterLock = NSLock()
    private static nonisolated(unsafe) let formatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .binary
        return f
    }()

    static func bytes(_ count: Int) -> String {
        // ByteCountFormatter spells small values out as "390 bytes", which is too wide for a row.
        if count < 1024 { return "\(count) B" }
        formatterLock.lock()
        defer { formatterLock.unlock() }
        return formatter.string(fromByteCount: Int64(count))
    }

    /// "↑ 3 MB  ↓ 40 MB", plus the live rate while data is flowing.
    static func summary(_ traffic: Traffic) -> String {
        var text = "↑ \(bytes(traffic.up))  ↓ \(bytes(traffic.down))"
        if traffic.upRate >= 1 || traffic.downRate >= 1 {
            text += " · ↑ \(bytes(Int(traffic.upRate)))/s  ↓ \(bytes(Int(traffic.downRate)))/s"
        }
        return text
    }
}

/// Watches tracked `ssh` processes with one shared `nettop` instance and reports cumulative
/// loopback bytes per PID.
///
/// ssh exposes no counters, but every byte a local client sends or receives crosses a loopback
/// socket owned by the ssh process, so `nettop -t loopback` gives the payload without SSH
/// overhead. A pty keeps `nettop` line-buffered instead of block-buffering for minutes.
final class TrafficMonitor: @unchecked Sendable {
    private static let headerBytes = Array(",bytes_in,bytes_out,".utf8)

    private let process = Process()
    private let reader: FileHandle
    private let lock = NSLock()
    private var trackedPIDs: Set<Int32> = []
    private var pendingBytes: [UInt8] = []
    private var stopped = false
    private var notifiedExit = false

    init?(
        onSamples: @escaping @Sendable ([Int32: (up: Int, down: Int)]) -> Void,
        onUnexpectedExit: (@Sendable () -> Void)? = nil
    ) {
        var master: Int32 = -1
        var slave: Int32 = -1
        guard openpty(&master, &slave, nil, nil, nil) == 0 else { return nil }
        reader = FileHandle(fileDescriptor: master, closeOnDealloc: true)
        let slaveHandle = FileHandle(fileDescriptor: slave, closeOnDealloc: false)

        process.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        process.arguments = ["-n", "-m", "tcp", "-t", "loopback", "-P", "-L", "0", "-s", "1", "-J", "bytes_in,bytes_out"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = slaveHandle
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] _ in
            guard let self else { return }
            let shouldNotify = self.lock.withLock { () -> Bool in
                if self.stopped || self.notifiedExit { return false }
                self.notifiedExit = true
                return true
            }
            if shouldNotify {
                onUnexpectedExit?()
            }
        }
        do {
            try process.run()
        } catch {
            close(slave)
            return nil
        }
        close(slave)  // the child holds its own copy; keeping ours would stop EOF from ever arriving

        reader.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else {
                handle.readabilityHandler = nil
                return
            }
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self.processChunk(data, onSamples: onSamples)
        }
    }

    var processIdentifier: Int32 { process.processIdentifier }

    func track(pid: Int32) {
        guard pid > 0 else { return }
        lock.withLock { _ = trackedPIDs.insert(pid) }
    }

    func untrack(pid: Int32) {
        lock.withLock { _ = trackedPIDs.remove(pid) }
    }

    func stop() {
        let alreadyStopped = lock.withLock { () -> Bool in
            if stopped { return true }
            stopped = true
            return false
        }
        guard !alreadyStopped else { return }
        reader.readabilityHandler = nil
        if process.isRunning { process.terminate() }
    }

    private func processChunk(
        _ data: Data,
        onSamples: @escaping @Sendable ([Int32: (up: Int, down: Int)]) -> Void
    ) {
        let (tracked, framesToEmit) = lock.withLock { () -> (Set<Int32>, [[Int32: (up: Int, down: Int)]]) in
            if stopped { return ([], []) }
            pendingBytes.append(contentsOf: data)
            var frames: [[Int32: (up: Int, down: Int)]] = []
            var batch: [Int32: (up: Int, down: Int)] = [:]
            var lineStart = 0

            for i in 0..<pendingBytes.count {
                if pendingBytes[i] == 0x0A {
                    var lineEnd = i
                    if lineEnd > lineStart && pendingBytes[lineEnd - 1] == 0x0D {
                        lineEnd -= 1
                    }
                    let slice = pendingBytes[lineStart..<lineEnd]
                    if slice.elementsEqual(Self.headerBytes) {
                        if !batch.isEmpty {
                            frames.append(batch)
                            batch.removeAll(keepingCapacity: true)
                        }
                    } else if !trackedPIDs.isEmpty, let parsed = Self.parseUTF8(slice), trackedPIDs.contains(parsed.pid) {
                        batch[parsed.pid] = (parsed.up, parsed.down)
                    }
                    lineStart = i + 1
                }
            }
            if lineStart > 0 {
                pendingBytes.removeFirst(lineStart)
            }
            if !batch.isEmpty {
                frames.append(batch)
            }
            return (trackedPIDs, frames)
        }

        guard !tracked.isEmpty else { return }
        for frame in framesToEmit {
            onSamples(frame)
        }
    }

    /// Parses a CSV row like `ssh.1234,390,870,` or any `<name>.<pid>,up,down,`.
    /// Header rows and non-numeric fields yield nil.
    static func parse(_ line: String) -> (pid: Int32, up: Int, down: Int)? {
        if let result = line.utf8.withContiguousStorageIfAvailable({ buf in
            parseUTF8(buf[0..<buf.count])
        }) {
            return result
        }
        let bytes = Array(line.utf8)
        return parseUTF8(bytes[0..<bytes.count])
    }

    private static func parseUTF8<C: RandomAccessCollection>(_ bytes: C) -> (pid: Int32, up: Int, down: Int)?
    where C.Element == UInt8, C.Index == Int {
        let start = bytes.startIndex
        let end = bytes.endIndex
        guard start < end else { return nil }

        // Field 0: <name>.<pid>
        guard let comma1 = bytes[start..<end].firstIndex(of: 0x2C), comma1 > start else { return nil }
        guard let dot = bytes[start..<comma1].lastIndex(of: 0x2E), dot > start else { return nil }
        guard let pid = parseInt32(bytes[(dot + 1)..<comma1]), pid > 0 else { return nil }

        // Field 1: bytes_in (up)
        let f1Start = comma1 + 1
        guard f1Start < end, let comma2 = bytes[f1Start..<end].firstIndex(of: 0x2C) else { return nil }
        guard let up = parseInt(bytes[f1Start..<comma2]) else { return nil }

        // Field 2: bytes_out (down)
        let f2Start = comma2 + 1
        guard f2Start < end else { return nil }
        let f2End = bytes[f2Start..<end].firstIndex(of: 0x2C) ?? end
        guard let down = parseInt(bytes[f2Start..<f2End]) else { return nil }

        return (pid, up, down)
    }

    private static func parseInt32<C: RandomAccessCollection>(_ bytes: C) -> Int32?
    where C.Element == UInt8, C.Index == Int {
        guard !bytes.isEmpty else { return nil }
        var value: Int32 = 0
        for byte in bytes {
            guard byte >= 0x30 && byte <= 0x39 else { return nil }
            let digit = Int32(byte - 0x30)
            let (mul, mulOverflow) = value.multipliedReportingOverflow(by: 10)
            if mulOverflow { return nil }
            let (add, addOverflow) = mul.addingReportingOverflow(digit)
            if addOverflow { return nil }
            value = add
        }
        return value
    }

    private static func parseInt<C: RandomAccessCollection>(_ bytes: C) -> Int?
    where C.Element == UInt8, C.Index == Int {
        guard !bytes.isEmpty else { return nil }
        var value = 0
        for byte in bytes {
            guard byte >= 0x30 && byte <= 0x39 else { return nil }
            let digit = Int(byte - 0x30)
            let (mul, mulOverflow) = value.multipliedReportingOverflow(by: 10)
            if mulOverflow { return nil }
            let (add, addOverflow) = mul.addingReportingOverflow(digit)
            if addOverflow { return nil }
            value = add
        }
        return value
    }
}
