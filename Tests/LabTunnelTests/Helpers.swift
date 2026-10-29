import Foundation

/// A stand-in for `/usr/bin/ssh` that ignores its arguments and sleeps. A tunnel started with it
/// stays in `connecting` without touching the network, which lets tests drive live tunnels.
func makeFakeSSH() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("fake-ssh-\(UUID().uuidString)")
    try "#!/bin/sh\nexec sleep 30\n".write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
}

func temporaryStoreURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("lt-\(UUID())/tunnels.json")
}

/// A loopback port that nothing listens on right now.
func freeLocalPort() -> Int {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    defer { close(fd) }
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")  // port 0: the kernel picks one
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    withUnsafeMutablePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            _ = bind(fd, $0, len)
            _ = getsockname(fd, $0, &len)
        }
    }
    return Int(UInt16(bigEndian: addr.sin_port))
}
