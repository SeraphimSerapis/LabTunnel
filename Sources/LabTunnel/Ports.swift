import Darwin

private func loopbackAddress(port: Int) -> sockaddr_in {
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = in_port_t(UInt16(port)).bigEndian
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    return addr
}

/// True if something already listens on 127.0.0.1:`port`.
/// Binding fails with EADDRINUSE while a live listener holds the port, which avoids shelling
/// out to `lsof` and avoids poking the tunnel with a probe connection. SO_REUSEADDR is
/// essential: without it, sockets lingering in TIME_WAIT (left behind by closed probe
/// connections) make a freed port look busy for up to 30 seconds.
func isLocalPortInUse(_ port: Int) -> Bool {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }

    var reuse: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

    var addr = loopbackAddress(port: port)
    let result = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    return result != 0 && errno == EADDRINUSE
}

/// The first port at or above `start` that is neither listening nor in `reserved`.
func firstFreePort(from start: Int, skipping reserved: Set<Int> = [], attempts: Int = 200) -> Int? {
    guard start <= 65535 else { return nil }
    for port in start...min(65535, start + attempts) where !reserved.contains(port) && !isLocalPortInUse(port) {
        return port
    }
    return nil
}

/// Asks whether anything answers behind a live forward on 127.0.0.1:`localPort`.
///
/// ssh accepts the local connection first, then tries the remote side. If the remote port is
/// closed, ssh drops our connection within a round trip, so EOF or a reset means "nothing
/// listening". Silence means a service waiting for the client to speak, and data means it
/// spoke first; both count as listening. Returns nil if the forward itself can't be reached.
/// Blocks for up to `timeoutMs`, so call it off the main thread.
func probeRemoteListening(localPort: Int, timeoutMs: Int32 = 1500) -> Bool? {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    defer { close(fd) }

    var addr = loopbackAddress(port: localPort)
    let connected = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard connected == 0 else { return nil }

    var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    let ready = poll(&pfd, 1, timeoutMs)
    if ready == 0 { return true }
    if ready < 0 { return nil }

    var byte: UInt8 = 0
    return recv(fd, &byte, 1, MSG_PEEK) > 0
}
