import Foundation

/// Stops processes LabTunnel started if LabTunnel dies without cleaning up.
///
/// macOS has no "kill my children when I die", so a crash or force-quit would leave `ssh`
/// running with its local port taken. Each watchdog is a small `sh` that blocks reading a pipe
/// whose write end only LabTunnel holds. When LabTunnel exits for any reason, the kernel closes
/// that end, the read returns, and the shell kills its targets. Nothing polls.
///
/// This relies on `Process` handing children only stdin, stdout and stderr. If the write end
/// leaked into another child, the read would not return until that child exited too.
/// `testWatchdogFiresWhileAnotherChildHoldsNoCopyOfTheLifeline` guards this.
final class Watchdog {
    private let process = Process()
    private let lifeline = Pipe()

    init(killing pids: [Int32]) throws {
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "read -r _; kill \"$@\" 2>/dev/null; exit 0", "labtunnel-watchdog"]
            + pids.map(String.init)
        process.standardInput = lifeline
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        // Our write end stays open until the shell is gone, so stop() can never make it fire.
        let lifeline = lifeline
        process.terminationHandler = { _ in try? lifeline.fileHandleForWriting.close() }
        try process.run()
    }

    /// Ends the watchdog without killing its targets.
    func stop() {
        if process.isRunning { process.terminate() }
    }

    func waitUntilExit() { process.waitUntilExit() }

    /// Does what the kernel does when LabTunnel dies. For tests.
    func simulateAppExit() { try? lifeline.fileHandleForWriting.close() }
}
