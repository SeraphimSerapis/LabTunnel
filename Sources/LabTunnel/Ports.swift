import Darwin

private func loopbackAddress(port: Int) -> sockaddr_in {
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = in_port_t(UInt16(port)).bigEndian
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    return addr
}

private func isIPv4BindBusy(address: in_addr_t, port: Int) -> Bool {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }

    var reuse: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = in_port_t(UInt16(port)).bigEndian
    addr.sin_addr.s_addr = address
    let result = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    return result != 0 && errno == EADDRINUSE
}

private func isIPv6BindBusy(address: in6_addr, port: Int) -> Bool {
    let fd = socket(AF_INET6, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }

    var v6only: Int32 = 1
    setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &v6only, socklen_t(MemoryLayout<Int32>.size))
    var reuse: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

    var addr = sockaddr_in6()
    addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
    addr.sin6_family = sa_family_t(AF_INET6)
    addr.sin6_port = in_port_t(UInt16(port)).bigEndian
    addr.sin6_addr = address
    let result = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
        }
    }
    return result != 0 && errno == EADDRINUSE
}

/// True if something already listens on `port` across IPv4/IPv6 loopback or wildcard addresses.
/// Binding fails with EADDRINUSE while a live listener holds the port, which avoids shelling
/// out to `lsof` and avoids poking the tunnel with a probe connection. SO_REUSEADDR is
/// essential: without it, sockets lingering in TIME_WAIT (left behind by closed probe
/// connections) make a freed port look busy for up to 30 seconds.
func isLocalPortInUse(_ port: Int) -> Bool {
    guard (1...65535).contains(port) else { return false }
    return isIPv4BindBusy(address: inet_addr("127.0.0.1"), port: port)
        || isIPv4BindBusy(address: INADDR_ANY, port: port)
        || isIPv6BindBusy(address: in6addr_loopback, port: port)
        || isIPv6BindBusy(address: in6addr_any, port: port)
}

/// True if `pid` has a listening IPv4 TCP socket on `127.0.0.1` or `0.0.0.0` at `port`.
func isProcessListening(pid: Int32, port: Int) -> Bool {
    guard pid > 0, (1...65535).contains(port) else { return false }
    let bytesNeeded = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
    guard bytesNeeded > 0 else { return false }

    let capacity = Int(bytesNeeded) / MemoryLayout<proc_fdinfo>.stride + 16
    var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
    let actualBytes = fds.withUnsafeMutableBytes { raw in
        proc_pidinfo(pid, PROC_PIDLISTFDS, 0, raw.baseAddress, Int32(raw.count))
    }
    guard actualBytes > 0 else { return false }

    let fdCount = Int(actualBytes) / MemoryLayout<proc_fdinfo>.stride
    let loopback = inet_addr("127.0.0.1")
    let socketInfoSize = Int32(MemoryLayout<socket_fdinfo>.size)

    for i in 0..<fdCount where fds[i].proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
        var info = socket_fdinfo()
        let readSize = proc_pidfdinfo(pid, fds[i].proc_fd, PROC_PIDFDSOCKETINFO, &info, socketInfoSize)
        guard readSize == socketInfoSize else { continue }
        let psi = info.psi
        guard psi.soi_family == AF_INET, psi.soi_kind == SOCKINFO_TCP else { continue }
        let tcp = psi.soi_proto.pri_tcp
        guard tcp.tcpsi_state == TSI_S_LISTEN else { continue }
        let localPort = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport)))
        guard localPort == port else { continue }
        let sAddr = tcp.tcpsi_ini.insi_laddr.ina_46.i46a_addr4.s_addr
        if sAddr == loopback || sAddr == INADDR_ANY {
            return true
        }
    }
    return false
}

/// The first port at or above `start` that is neither listening nor in `reserved`.
func firstFreePort(from start: Int, skipping reserved: Set<Int> = [], attempts: Int = 200) -> Int? {
    guard (1...65535).contains(start) else { return nil }
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
func probeRemoteListening(localPort: Int, timeoutMs: Int32 = 600) -> Bool? {
    guard (1...65535).contains(localPort) else { return nil }
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    defer { close(fd) }

    var noSigPipe: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

    var addr = loopbackAddress(port: localPort)
    let connected = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard connected == 0 else { return nil }

    let clampedTimeout = max(0, timeoutMs)
    let deadlineNs = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) &+ UInt64(clampedTimeout) * 1_000_000
    var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    var ready: Int32 = 0
    while true {
        let nowNs = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let remainingMs = nowNs >= deadlineNs ? 0 : Int32(min(UInt64(Int32.max), (deadlineNs - nowNs + 999_999) / 1_000_000))
        ready = poll(&pfd, 1, remainingMs)
        if ready < 0 && errno == EINTR {
            if nowNs >= deadlineNs {
                ready = 0
                break
            }
            continue
        }
        break
    }

    if ready == 0 { return true }
    if ready < 0 { return nil }

    var byte: UInt8 = 0
    return recv(fd, &byte, 1, MSG_PEEK) > 0
}
