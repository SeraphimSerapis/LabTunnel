import Darwin
import Foundation

/// Minimal blocking Unix-domain socket helpers for the line-based control protocol.
public enum UnixSocket {
    public struct Failure: Error, CustomStringConvertible {
        public let description: String
        init(_ description: String) { self.description = description }
    }

    private static func address(for path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)  // includes the terminating NUL
        guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            throw Failure("Socket path is too long: \(path)")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { destination in
            bytes.withUnsafeBytes { source in
                destination.baseAddress!.copyMemory(from: source.baseAddress!, byteCount: source.count)
            }
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return addr
    }

    private static func errnoMessage() -> String { String(cString: strerror(errno)) }

    /// Receive/send timeouts and no SIGPIPE: a peer that vanishes mid-write must not kill the app.
    public static func configure(_ fd: Int32, timeoutSeconds: Int) {
        var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        let size = socklen_t(MemoryLayout<timeval>.size)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, size)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, size)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Creates a listening socket at `path`, replacing a stale file, readable only by this user.
    public static func listen(path: String) throws -> Int32 {
        var addr = try address(for: path)
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure("socket: \(errnoMessage())") }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            let message = errnoMessage()
            close(fd)
            throw Failure("bind \(path): \(message)")
        }
        chmod(path, 0o600)
        guard Darwin.listen(fd, 16) == 0 else {
            let message = errnoMessage()
            close(fd)
            throw Failure("listen: \(message)")
        }
        return fd
    }

    public static func connect(path: String, timeoutSeconds: Int = 10) throws -> Int32 {
        var addr = try address(for: path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure("socket: \(errnoMessage())") }
        configure(fd, timeoutSeconds: timeoutSeconds)
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            let message = errnoMessage()
            close(fd)
            throw Failure("connect \(path): \(message)")
        }
        return fd
    }

    /// Reads up to the first newline. Nil on EOF before any data, timeout/error, or oversized input.
    public static func readLine(_ fd: Int32, maxBytes: Int = 1 << 20) -> Data? {
        guard maxBytes > 0 else { return nil }
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while data.count <= maxBytes {
            var count: Int
            repeat {
                count = read(fd, &chunk, chunk.count)
            } while count < 0 && errno == EINTR

            if count < 0 { return nil }
            if count == 0 { return data.isEmpty ? nil : data }

            if let newline = chunk[..<count].firstIndex(of: 0x0A) {
                guard data.count + newline <= maxBytes else { return nil }
                data.append(chunk, count: newline)
                return data
            }
            data.append(chunk, count: count)
        }
        return nil
    }

    public static func writeLine(_ fd: Int32, _ payload: Data) {
        var bytes = payload
        bytes.append(0x0A)
        var offset = 0
        bytes.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            while offset < buffer.count {
                let written = write(fd, base + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    return
                }
                if written == 0 { return }
                offset += written
            }
        }
    }
}

/// Advisory file lock keeping a single running app instance per data directory.
public final class InstanceLock: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32

    private init(fd: Int32) {
        self.fd = fd
    }

    deinit {
        release()
    }

    public static func acquire(at url: URL) -> InstanceLock? {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let fd = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { return nil }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            return nil
        }
        return InstanceLock(fd: fd)
    }

    public func release() {
        lock.lock()
        let currentFD = fd
        fd = -1
        lock.unlock()
        guard currentFD >= 0 else { return }
        flock(currentFD, LOCK_UN)
        close(currentFD)
    }
}
