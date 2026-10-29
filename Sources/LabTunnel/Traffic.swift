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
    private var carried = (up: 0, down: 0)
    private var last: (time: Date, up: Int, down: Int)?
    private(set) var current = Traffic()

    mutating func sample(up: Int, down: Int, at time: Date = Date()) {
        var rates = (up: 0.0, down: 0.0)
        if let last, time > last.time {
            let seconds = time.timeIntervalSince(last.time)
            rates = (max(0, Double(up - last.up) / seconds), max(0, Double(down - last.down) / seconds))
        }
        last = (time, up, down)
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
    static func bytes(_ count: Int) -> String {
        // ByteCountFormatter spells small values out as "390 bytes", which is too wide for a row.
        if count < 1024 { return "\(count) B" }
        return ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .binary)
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

/// Watches one `ssh` process with `nettop` and reports its cumulative loopback bytes.
///
/// ssh exposes no counters, but every byte a local client sends or receives crosses a loopback
/// socket owned by the ssh process, so `nettop -t loopback` gives the payload without SSH
/// overhead. Two quirks shape this class:
/// - nettop only remembers closed connections within one session, so a single long-lived
///   instance must watch from the start. One-shot samples would forget finished requests.
/// - nettop block-buffers when stdout isn't a terminal, which delays output by minutes.
///   A pty makes it line-buffered.
final class TrafficMonitor: @unchecked Sendable {
    /// Distinguishes this monitor from an earlier one for the same tunnel when late samples arrive.
    let generation: UUID
    private let process = Process()
    private let reader: FileHandle
    private var pending = ""

    init?(pid: Int32, generation: UUID, onSample: @escaping @Sendable (_ up: Int, _ down: Int) -> Void) {
        self.generation = generation
        var master: Int32 = -1
        var slave: Int32 = -1
        guard openpty(&master, &slave, nil, nil, nil) == 0 else { return nil }
        reader = FileHandle(fileDescriptor: master, closeOnDealloc: true)
        let slaveHandle = FileHandle(fileDescriptor: slave, closeOnDealloc: false)

        process.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        process.arguments = ["-p", String(pid), "-P", "-L", "0", "-s", "1", "-t", "loopback", "-J", "bytes_in,bytes_out"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = slaveHandle
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            close(slave)
            return nil
        }
        close(slave)  // the child holds its own copy; keeping ours would stop EOF from ever arriving

        reader.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self.pending += String(decoding: data, as: UTF8.self)
            var lines = self.pending.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            self.pending = String(lines.removeLast())
            for line in lines {
                if let (up, down) = Self.parse(String(line)) { onSample(up, down) }
            }
        }
    }

    var processIdentifier: Int32 { process.processIdentifier }

    func stop() {
        reader.readabilityHandler = nil
        if process.isRunning { process.terminate() }
    }

    /// Parses a CSV row like `ssh.1234,390,870,`. Header rows and other processes yield nil.
    static func parse(_ line: String) -> (up: Int, down: Int)? {
        let fields = line.split(separator: ",", omittingEmptySubsequences: false)
        guard fields.count >= 3, fields[0].hasPrefix("ssh."),
              let up = Int(fields[1]), let down = Int(fields[2]) else { return nil }
        return (up, down)
    }
}
