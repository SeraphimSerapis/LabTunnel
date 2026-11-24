import Darwin
import Foundation

/// Remembers the PIDs of `ssh` processes we started, so the next launch can clean up after a
/// crash or force-quit. Without this, an orphaned `ssh -N` keeps its local port forever.
struct PIDRegistry {
    let url: URL

    func add(_ pid: Int32) {
        var list = pids()
        if !list.contains(pid) {
            list.append(pid)
            save(list)
        }
    }

    func remove(_ pid: Int32) { save(pids().filter { $0 != pid }) }
    func clear() { save([]) }

    /// Terminates recorded processes that are still one of our tunnels, then forgets them.
    /// A recycled PID could now belong to one of the user's own `ssh` sessions, so the
    /// executable path alone isn't enough: the command line must carry our tunnel flags.
    func reapOrphans() {
        let existing = pids()
        if existing.isEmpty && !FileManager.default.fileExists(atPath: url.path) {
            return
        }
        for pid in existing where Self.isLabTunnelSSH(pid) {
            kill(pid, SIGTERM)
        }
        clear()
    }

    static func isLabTunnelSSH(_ pid: Int32) -> Bool {
        guard executablePath(of: pid) == "/usr/bin/ssh", let args = arguments(of: pid) else { return false }
        guard args.contains("-N"), args.contains("ControlPath=none") else { return false }
        return args.indices.contains { i in
            (args[i] == "-L" && i + 1 < args.count && args[i + 1].hasPrefix("127.0.0.1:"))
                || args[i].hasPrefix("-L127.0.0.1:")
        }
    }

    static func arguments(of pid: Int32) -> [String]? {
        guard pid > 0 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }

        var bufferSize = size + 1024
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        guard sysctl(&mib, 3, &buffer, &bufferSize, nil, 0) == 0,
              bufferSize > MemoryLayout<Int32>.size else { return nil }

        let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc >= 0 else { return nil }

        var index = MemoryLayout<Int32>.size
        // Skip exec_path and any trailing NUL alignment padding before argv[0].
        while index < bufferSize && buffer[index] != 0 { index += 1 }
        while index < bufferSize && buffer[index] == 0 { index += 1 }

        var args: [String] = []
        args.reserveCapacity(Int(argc))
        for _ in 0..<argc {
            guard index < bufferSize else { break }
            let start = index
            while index < bufferSize && buffer[index] != 0 { index += 1 }
            args.append(String(decoding: buffer[start..<index], as: UTF8.self))
            if index < bufferSize { index += 1 }
        }
        return args
    }

    static func commandLine(of pid: Int32) -> String? {
        arguments(of: pid)?.joined(separator: " ")
    }

    private func pids() -> [Int32] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Int32].self, from: data)) ?? []
    }

    private func save(_ pids: [Int32]) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(pids).write(to: url, options: .atomic)
    }

    static func executablePath(of pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        return proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : nil
    }
}
