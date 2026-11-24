import Darwin
import Foundation

/// Stops processes LabTunnel started if LabTunnel dies without cleaning up.
///
/// macOS has no "kill my children when I die", so a crash or force-quit would leave `ssh`
/// running with its local port taken. One shared watchdog runs `/bin/sh` reading commands from
/// a pipe whose write end only LabTunnel holds. When LabTunnel exits for any reason, the kernel
/// closes that end, `read` hits EOF, and the shell kills all currently tracked PIDs.
///
/// This relies on `Process` handing children only stdin, stdout and stderr. If the write end
/// leaked into another child, the read would not return until that child exited too.
/// `testWatchdogFiresWhileAnotherChildHoldsNoCopyOfTheLifeline` guards this.
final class Watchdog: @unchecked Sendable {
    private static let script = """
    pids=""
    while IFS= read -r line; do
      case "$line" in
        +*)
          p=${line#+}
          case " $pids " in
            *" $p "*) ;;
            *) pids="$pids $p" ;;
          esac
          ;;
        -*)
          p=${line#-}
          new=""
          for x in $pids; do
            [ "$x" = "$p" ] || new="$new $x"
          done
          pids=$new
          ;;
        q)
          exit 0
          ;;
      esac
    done
    set -- $pids
    [ $# -gt 0 ] && kill "$@" 2>/dev/null
    exit 0
    """

    private let process = Process()
    private let lifeline = Pipe()
    private let lock = NSLock()
    private var writeClosed = false
    private var stopped = false

    var isRunning: Bool { process.isRunning }

    init() throws {
        // Pipes on macOS ignore SO_NOSIGPIPE; F_SETNOSIGPIPE turns broken-pipe writes into EPIPE.
        _ = fcntl(lifeline.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", Self.script, "labtunnel-watchdog"]
        process.standardInput = lifeline
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] _ in
            self?.closeWriteEnd()
        }
        do {
            try process.run()
        } catch {
            closeWriteEnd()
            try? lifeline.fileHandleForReading.close()
            throw error
        }
        // Only the watchdog needs the read end; closing ours keeps EPIPE accurate if it dies early.
        try? lifeline.fileHandleForReading.close()
    }

    convenience init(killing pids: [Int32]) throws {
        try self.init()
        for pid in pids {
            track(pid)
        }
    }

    func track(_ pid: Int32) {
        guard pid > 0 else { return }
        writeCommand("+\(pid)\n")
    }

    func untrack(_ pid: Int32) {
        guard pid > 0 else { return }
        writeCommand("-\(pid)\n")
    }

    /// Ends the watchdog cleanly without killing its tracked targets. Idempotent.
    func stop() {
        let shouldWait: Bool = lock.withLock {
            if stopped { return false }
            stopped = true
            if !writeClosed {
                writeAllLocked("q\n")
                closeWriteEndLocked()
            }
            return true
        }
        guard shouldWait else { return }

        let deadline = Date().addingTimeInterval(0.5)
        while process.isRunning && Date() < deadline {
            usleep(2_000)
        }
        if process.isRunning {
            process.terminate()
        }
    }

    func waitUntilExit() { process.waitUntilExit() }

    /// Does what the kernel does when LabTunnel dies. For tests.
    func simulateAppExit() { closeWriteEnd() }

    private func writeCommand(_ command: String) {
        lock.lock()
        defer { lock.unlock() }
        guard !writeClosed, !stopped else { return }
        writeAllLocked(command)
    }

    private func writeAllLocked(_ text: String) {
        let fd = lifeline.fileHandleForWriting.fileDescriptor
        let bytes = Array(text.utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { raw in
                Darwin.write(fd, raw.baseAddress!.advanced(by: offset), bytes.count - offset)
            }
            if written > 0 {
                offset += written
            } else if written < 0 && errno == EINTR {
                continue
            } else {
                closeWriteEndLocked()
                break
            }
        }
    }

    private func closeWriteEnd() {
        lock.lock()
        defer { lock.unlock() }
        closeWriteEndLocked()
    }

    private func closeWriteEndLocked() {
        guard !writeClosed else { return }
        writeClosed = true
        try? lifeline.fileHandleForWriting.close()
    }
}
