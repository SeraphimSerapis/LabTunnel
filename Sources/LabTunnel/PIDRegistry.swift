import Darwin
import Foundation

/// Remembers the PIDs of `ssh` processes we started, so the next launch can clean up after a
/// crash or force-quit. Without this, an orphaned `ssh -N` keeps its local port forever.
struct PIDRegistry {
    let url: URL

    func add(_ pid: Int32) { save(pids() + [pid]) }
    func remove(_ pid: Int32) { save(pids().filter { $0 != pid }) }
    func clear() { save([]) }

    /// Terminates recorded processes that are still one of our tunnels, then forgets them.
    /// A recycled PID could now belong to one of the user's own `ssh` sessions, so the
    /// executable path alone isn't enough: the command line must carry our tunnel flags.
    func reapOrphans() {
        for pid in pids() where Self.isLabTunnelSSH(pid) {
            kill(pid, SIGTERM)
        }
        clear()
    }

    static func isLabTunnelSSH(_ pid: Int32) -> Bool {
        guard executablePath(of: pid) == "/usr/bin/ssh", let command = commandLine(of: pid) else { return false }
        return command.contains(" -N ") && command.contains("ControlPath=none") && command.contains("-L 127.0.0.1:")
    }

    static func commandLine(of pid: Int32) -> String? {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-o", "command=", "-p", String(pid)]
        let out = Pipe()
        ps.standardOutput = out
        ps.standardError = FileHandle.nullDevice
        guard (try? ps.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text : nil
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
