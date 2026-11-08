import Foundation
import Network

/// 线程安全的统计计数（写 App Group 前聚合）
final class BridgeStats {
    private let lock = NSLock()
    private var _tx: Int64 = 0
    private var _rx: Int64 = 0
    private var _active = 0
    private var _dns: Int64 = 0
    private var _udpDropped: Int64 = 0

    var tx: Int64 { lock.lock(); defer { lock.unlock() }; return _tx }
    var rx: Int64 { lock.lock(); defer { lock.unlock() }; return _rx }
    var active: Int { lock.lock(); defer { lock.unlock() }; return _active }
    var dns: Int64 { lock.lock(); defer { lock.unlock() }; return _dns }
    var udpDropped: Int64 { lock.lock(); defer { lock.unlock() }; return _udpDropped }

    func addTx(_ n: Int) { lock.lock(); _tx += Int64(n); lock.unlock() }
    func addRx(_ n: Int) { lock.lock(); _rx += Int64(n); lock.unlock() }
    func addActive(_ n: Int) { lock.lock(); _active += n; lock.unlock() }
    func addDns() { lock.lock(); _dns += 1; lock.unlock() }
    func addUdpDropped() { lock.lock(); _udpDropped += 1; lock.unlock() }
}

/// SOCKS5 本地桥（127.0.0.1:10808）：no-auth + CONNECT 子集 + UDP ASSOCIATE（仅 DNS）。
/// CONNECT 转发条款与 Android Kotlin 版逐条对齐（doc/vpn-forwarding-design.md §4）。
final class Socks5Bridge {
    let stats = BridgeStats()

    /// 当前上游（host, port）；由 PacketTunnelProvider 在 start 前注入
    private var upstream: (String, Int)
    private let successHandler: () -> Void
    private let failureHandler: (String) -> Void

    private var listenFd: Int32 = -1
    private var udpFd: Int32 = -1
    private var running = false
    private let queue = DispatchQueue(label: "proxyscan.socks5.accept", qos: .utility)

    init(upstream: (String, Int), onSuccess: @escaping () -> Void, onFailure: @escaping (String) -> Void) {
        self.upstream = upstream
        self.successHandler = onSuccess
        self.failureHandler = onFailure
    }

    /// 启动监听；失败抛错（端口占用等）。
    func start() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw errnoError("socket") }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(ProxyScanPorts.socks5).bigEndian
        addr.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { close(fd); throw errnoError("bind 10808") }
        guard listen(fd, 128) == 0 else { close(fd); throw errnoError("listen") }

        listenFd = fd
        running = true
        queue.async { self.acceptLoop() }
    }

    func stop() {
        running = false
        if listenFd >= 0 { shutdown(listenFd, SHUT_RDWR); close(listenFd); listenFd = -1 }
        if udpFd >= 0 { close(udpFd); udpFd = -1 }
    }

    // MARK: - accept 循环

    private func acceptLoop() {
        while running {
            var addr = sockaddr()
            var len = socklen_t(MemoryLayout<sockaddr>.size)
            let client = accept(listenFd, &addr, &len)
            if client < 0 { continue }
            DispatchQueue.global(qos: .utility).async { self.handleConnection(client) }
        }
    }

    // MARK: - 单连接：方法协商 + 命令分发

    private func handleConnection(_ fd: Int32) {
        stats.addActive(1)
        defer { close(fd); stats.addActive(-1) }

        // 方法协商：VER=5, NMETHODS, METHODS... → 05 00（no-auth）
        var head = [UInt8](repeating: 0, count: 2)
        guard readFully(fd, &head, 2) else { return }
        guard head[0] == 5 else { return }
        var methods = [UInt8](repeating: 0, count: Int(head[1]))
        guard readFully(fd, &methods, methods.count) else { return }
        guard methods.contains(0) else {
            _ = writeAll(fd, [0x05, 0xFF]); return
        }
        guard writeAll(fd, [0x05, 0x00]) else { return }

        // 请求：VER CMD RSV ATYP DST.ADDR DST.PORT
        var req = [UInt8](repeating: 0, count: 4)
        guard readFully(fd, &req, 4), req[0] == 5 else { return }
        guard let target = readAddress(fd, atyp: req[3]) else { return }
        NSLog("[ProxyScan] socks5: 新连接 cmd=%d target=%@:%d", req[1], target.host, target.port)

        switch req[1] {
        case 0x01: // CONNECT
            handleConnect(fd, target: target)
        case 0x03: // UDP ASSOCIATE
            handleUdpAssociate(fd, target: target)
        default:
            _ = writeAll(fd, [0x05, 0x07, 0x00, 0x01, 0, 0, 0, 0, 0, 0]) // command not supported
        }
    }

    /// 解析 SOCKS5 地址字段；返回 (host, port) 与原始字节（回包用）
    private func readAddress(_ fd: Int32, atyp: UInt8) -> (host: String, port: Int, raw: [UInt8])? {
        var raw = [atyp]
        switch atyp {
        case 0x01: // IPv4
            var b = [UInt8](repeating: 0, count: 6)
            guard readFully(fd, &b, 6) else { return nil }
            raw += b
            let host = "\(b[0]).\(b[1]).\(b[2]).\(b[3])"
            let port = (Int(b[4]) << 8) | Int(b[5])
            return (host, port, raw)
        case 0x03: // 域名
            var lenBuf = [UInt8](repeating: 0, count: 1)
            guard readFully(fd, &lenBuf, 1) else { return nil }
            let n = Int(lenBuf[0])
            var b = [UInt8](repeating: 0, count: n + 2)
            guard readFully(fd, &b, b.count) else { return nil }
            raw += lenBuf + b
            guard let host = String(bytes: b[0..<n], encoding: .utf8) else { return nil }
            let port = (Int(b[n]) << 8) | Int(b[n + 1])
            return (host, port, raw)
        case 0x04: // IPv6
            var b = [UInt8](repeating: 0, count: 18)
            guard readFully(fd, &b, 18) else { return nil }
            raw += b
            var addr = in6_addr()
            withUnsafeMutableBytes(of: &addr) { dst in
                dst.copyBytes(from: b[0..<16])
            }
            var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            guard inet_ntop(AF_INET6, &addr, &buf, socklen_t(INET6_ADDRSTRLEN)) != nil else { return nil }
            let host = String(cString: buf)
            let port = (Int(b[16]) << 8) | Int(b[17])
            return (host, port, raw)
        default:
            return nil
        }
    }

    // MARK: - CONNECT（§4 条款）

    private func handleConnect(_ clientFd: Int32, target: (host: String, port: Int, raw: [UInt8])) {
        // 目标为环回 → 本机直连（与 Android 一致，防套娃）
        if target.host == "127.0.0.1" || target.host == "::1" || target.host.lowercased() == "localhost" {
            guard directConnectAndRelay(clientFd, target: target) else { return }
            return
        }

        let up = upstream
        let bracketedHost = target.host.contains(":") ? "[\(target.host)]" : target.host
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var resolved: UnsafeMutablePointer<addrinfo>?
        let gai = getaddrinfo(up.0, String(up.1), &hints, &resolved)
        guard gai == 0, resolved != nil else {
            failureHandler("DNS 解析上游失败 \(up.0)")
            _ = writeAll(clientFd, [0x05, 0x04, 0x00, 0x01, 0, 0, 0, 0, 0, 0]) // host unreachable
            return
        }

        var upstreamFd: Int32 = -1
        var rp: UnsafeMutablePointer<addrinfo>? = resolved
        while let cur = rp {
            let cand = socket(cur.pointee.ai_family, cur.pointee.ai_socktype, cur.pointee.ai_protocol)
            if cand >= 0 {
                // 10s 连接超时
                var tv = timeval(tv_sec: 10, tv_usec: 0)
                setsockopt(cand, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                let ok = connect(cand, cur.pointee.ai_addr, cur.pointee.ai_addrlen)
                if ok == 0 { upstreamFd = cand; break }
                close(cand)
            }
            rp = cur.pointee.ai_next
        }
        freeaddrinfo(resolved)

        guard upstreamFd >= 0 else {
            failureHandler("连不上上游 \(up.0):\(up.1)")
            _ = writeAll(clientFd, [0x05, 0x05, 0x00, 0x01, 0, 0, 0, 0, 0, 0]) // connection refused
            return
        }

        // CONNECT 握手：发请求 → 严格解析响应头；非 2xx 透传给客户端；200 后残余字节原样转发
        let request = "CONNECT \(bracketedHost):\(target.port) HTTP/1.1\r\nHost: \(bracketedHost):\(target.port)\r\n\r\n"
        guard writeAll(upstreamFd, Array(request.utf8)) else { close(upstreamFd); return }

        guard let (status, leftover) = readConnectResponse(upstreamFd) else {
            failureHandler("上游 \(up.0):\(up.1) 握手无响应")
            close(upstreamFd)
            _ = writeAll(clientFd, [0x05, 0x05, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
            return
        }

        guard (200...299).contains(status) else {
            // 非 2xx：响应头 + 残余字节原样透传给应用侧
            failureHandler("上游返回非 2xx（\(status)）")
            _ = writeAll(clientFd, leftover)
            close(upstreamFd)
            return
        }

        // 成功：回 SOCKS5 成功应答（残余 leftover 是隧道内首包数据）
        guard writeAll(clientFd, [0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]) else {
            close(upstreamFd); return
        }
        if !leftover.isEmpty {
            guard writeAll(clientFd, leftover) else { close(upstreamFd); return }
        }
        successHandler()

        relayBidirectional(clientFd: clientFd, upstreamFd: upstreamFd)
    }

    /// 读取 CONNECT 响应直到 \r\n\r\n；返回 (状态码, 头后残余字节)
    private func readConnectResponse(_ fd: Int32) -> (Int, [UInt8])? {
        var buf = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while buf.count < 64 * 1024 {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { return nil }
            buf.append(contentsOf: chunk[0..<n])
            if let range = findHeaderEnd(buf) {
                let header = buf[0..<range.0]
                let leftover = Array(buf[range.1...])
                let lineEnd = header.firstIndex(of: 0x20) ?? header.endIndex
                let statusStr = String(bytes: header[header.startIndex..<lineEnd], encoding: .ascii) ?? ""
                let codeStr = String(bytes: header[header.index(after: header.startIndex)..<lineEnd], encoding: .ascii) ?? ""
                // 状态行形如 "HTTP/1.1 200"
                let parts = statusStr.split(separator: " ")
                if parts.count >= 2, let status = Int(parts[1]) {
                    return (status, leftover)
                }
                if let status = Int(codeStr.prefix(while: { $0.isNumber })) { return (status, leftover) }
                return nil
            }
        }
        return nil
    }

    private func findHeaderEnd(_ buf: [UInt8]) -> (Int, Int)? {
        // 返回 (\r\n\r\n 起始下标, 其后首字节下标)
        guard buf.count >= 4 else { return nil }
        for i in 0...(buf.count - 4) where buf[i] == 0x0D && buf[i+1] == 0x0A && buf[i+2] == 0x0D && buf[i+3] == 0x0A {
            return (i, i + 4)
        }
        return nil
    }

    // MARK: - 双向 relay（半关闭传播 + RST 静默关双 + 字节计数，§4）

    private func relayBidirectional(clientFd: Int32, upstreamFd: Int32) {
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            self.pump(src: upstreamFd, dst: clientFd, countTx: false)
            group.leave()
        }
        // 主线程方向：client → upstream，之后关 upstream 写口
        pump(src: clientFd, dst: upstreamFd, countTx: true)
        group.wait()
        shutdown(clientFd, SHUT_RDWR); close(clientFd)
        shutdown(upstreamFd, SHUT_RDWR); close(upstreamFd)
    }

    /// 单向泵：src read → dst write；EOF → shutdown(dst, WR)；RST/错误 → 对向也关（由上层收尾）
    private func pump(src: Int32, dst: Int32, countTx: Bool) {
        var buf = [UInt8](repeating: 0, count: 16384)
        while true {
            let n = read(src, &buf, buf.count)
            if n == 0 {
                shutdown(dst, SHUT_WR) // 半关闭传播
                return
            }
            if n < 0 {
                if errno == EINTR { continue }
                return // RST 或错误：静默退出，双向关闭由 relay 收尾
            }
            if countTx { stats.addTx(n) } else { stats.addRx(n) }
            if !writeAll(dst, Array(buf[0..<n])) { return }
        }
    }

    // MARK: - 环回目标本机直连

    private func directConnectAndRelay(_ clientFd: Int32, target: (host: String, port: Int, raw: [UInt8])) -> Bool {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var resolved: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(target.host, String(target.port), &hints, &resolved) == 0, resolved != nil else {
            _ = writeAll(clientFd, [0x05, 0x04, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
            return false
        }
        var fd: Int32 = -1
        var rp: UnsafeMutablePointer<addrinfo>? = resolved
        while let cur = rp {
            let cand = socket(cur.pointee.ai_family, cur.pointee.ai_socktype, cur.pointee.ai_protocol)
            if cand >= 0 && connect(cand, cur.pointee.ai_addr, cur.pointee.ai_addrlen) == 0 {
                fd = cand; break
            }
            if cand >= 0 { close(cand) }
            rp = cur.pointee.ai_next
        }
        freeaddrinfo(resolved)
        guard fd >= 0 else {
            _ = writeAll(clientFd, [0x05, 0x05, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
            return false
        }
        guard writeAll(clientFd, [0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]) else { close(fd); return false }
        successHandler()
        relayBidirectional(clientFd: clientFd, upstreamFd: fd)
        return true
    }

    // MARK: - UDP ASSOCIATE（RFC 1928；仅放行目标端口 53 → 223.5.5.5，其余丢弃计数）

    private func handleUdpAssociate(_ clientFd: Int32, target: (host: String, port: Int, raw: [UInt8])) {
        // 开 UDP 口收客户端 datagram
        let udp = socket(AF_INET, SOCK_DGRAM, 0)
        guard udp >= 0 else {
            _ = writeAll(clientFd, [0x05, 0x01, 0x00, 0x01, 0, 0, 0, 0, 0, 0]); return
        }
        var bound = sockaddr_in()
        bound.sin_family = sa_family_t(AF_INET)
        bound.sin_port = 0
        bound.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)
        let bindOk = withUnsafePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(udp, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindOk == 0 else { close(udp); return }
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(udp, $0, &addrLen)
            }
        }
        let relayPort = Int(in_port_t(bigEndian: bound.sin_port))

        // 应答 BND.ADDR=127.0.0.1 BND.PORT
        var reply: [UInt8] = [0x05, 0x00, 0x00, 0x01, 127, 0, 0, 1]
        reply.append(UInt8(relayPort >> 8)); reply.append(UInt8(relayPort & 0xFF))
        guard writeAll(clientFd, reply) else { close(udp); return }
        udpFd = udp

        // UDP 转发循环（超时轮询以便 stop 退出）
        var buf = [UInt8](repeating: 0, count: 65535)
        var pollSet = pollfd(fd: udp, events: Int16(POLLIN), revents: 0)
        while running {
            let pr = poll(&pollSet, 1, 500)
            if pr <= 0 || (pollSet.revents & Int16(POLLIN)) == 0 { continue }

            var srcAddr = sockaddr_storage()
            var srcLen = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let n = withUnsafeMutablePointer(to: &srcAddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(udp, &buf, buf.count, 0, $0, &srcLen)
                }
            }
            if n <= 3 { continue }
            let pkt = Array(buf[0..<n])

            // RFC 1928：RSV(2) FRAG(1) ATYP(1) ADDR PORT DATA；FRAG!=0 不支持，丢弃
            guard pkt[0] == 0, pkt[1] == 0, pkt[2] == 0 else { stats.addUdpDropped(); continue }
            guard let (dstHost, dstPort, hdrLen) = parseUdpTarget(pkt) else { stats.addUdpDropped(); continue }
            guard dstPort == 53 else { stats.addUdpDropped(); continue } // 非 53 UDP 按设计丢弃

            let payload = Array(pkt[hdrLen...])
            // 并发查询：forwardDns 内阻塞 recv 最长 10s，不得卡住 UDP 收包循环
            DispatchQueue.global(qos: .utility).async {
                self.forwardDns(payload, to: dstHost, via: udp, client: srcAddr, clientLen: srcLen)
            }
        }
        close(udp)
    }

    private func parseUdpTarget(_ pkt: [UInt8]) -> (String, Int, Int)? {
        guard pkt.count >= 5 else { return nil }
        switch pkt[3] {
        case 0x01:
            guard pkt.count >= 11 else { return nil }
            let host = "\(pkt[4]).\(pkt[5]).\(pkt[6]).\(pkt[7])"
            let port = (Int(pkt[8]) << 8) | Int(pkt[9])
            return (host, port, 10)
        case 0x03:
            let n = Int(pkt[4])
            guard pkt.count >= 5 + n + 2 else { return nil }
            guard let host = String(bytes: pkt[5..<(5 + n)], encoding: .utf8) else { return nil }
            let p = 5 + n
            let port = (Int(pkt[p]) << 8) | Int(pkt[p + 1])
            return (host, port, p + 2)
        case 0x04:
            guard pkt.count >= 23 else { return nil }
            var addr = in6_addr()
            withUnsafeMutableBytes(of: &addr) { $0.copyBytes(from: pkt[4..<20]) }
            var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            guard inet_ntop(AF_INET6, &addr, &buf, socklen_t(INET6_ADDRSTRLEN)) != nil else { return nil }
            let port = (Int(pkt[20]) << 8) | Int(pkt[21])
            return (String(cString: buf), port, 22)
        default:
            return nil
        }
    }

    /// DNS payload 经扩展进程内 UDP 直连 223.5.5.5（天然不过隧道，等同 Android protect()）
    private func forwardDns(_ payload: [UInt8], to dstHost: String, via udpFd: Int32, client: sockaddr_storage, clientLen: socklen_t) {
        // 设计口径：无论目标 DNS 是谁，一律转发 223.5.5.5（与 Android DnsForwarder 一致）
        _ = dstHost
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_DGRAM
        var resolved: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(ProxyScanPorts.dnsServer, "53", &hints, &resolved) == 0, let rp = resolved else { return }

        let queryFd = socket(rp.pointee.ai_family, rp.pointee.ai_socktype, rp.pointee.ai_protocol)
        guard queryFd >= 0 else { freeaddrinfo(resolved); return }

        var tv = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(queryFd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let sent = payload.withUnsafeBytes { ptr -> Int in
            sendto(queryFd, ptr.baseAddress, payload.count, 0, rp.pointee.ai_addr, rp.pointee.ai_addrlen)
        }
        freeaddrinfo(resolved)
        guard sent == payload.count else { close(queryFd); return }

        var resp = [UInt8](repeating: 0, count: 65535)
        let rn = recv(queryFd, &resp, resp.count, 0)
        close(queryFd)
        guard rn > 0 else { return }

        // 回包重封装：RSV FRAG ATYP(IPv4) SRC.ADDR SRC.PORT DATA
        var outPkt: [UInt8] = [0, 0, 0, 0x01]
        // 源地址填实际应答来源（223.5.5.5 四段）
        let dnsParts = ProxyScanPorts.dnsServer.split(separator: ".").compactMap { UInt8($0) }
        outPkt += dnsParts.count == 4 ? dnsParts : [223, 5, 5, 5]
        outPkt += [0, 53]
        outPkt += Array(resp[0..<rn])

        withUnsafePointer(to: client) { clientPtr in
            clientPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                _ = outPkt.withUnsafeBytes { ptr in
                    sendto(udpFd, ptr.baseAddress, outPkt.count, 0, sa, clientLen)
                }
            }
        }
        stats.addDns()
    }

    // MARK: - 读写工具

    private func readFully(_ fd: Int32, _ buf: inout [UInt8], _ n: Int) -> Bool {
        var off = 0
        while off < n {
            let r = read(fd, &buf[off], n - off)
            if r <= 0 { return false }
            off += r
        }
        return true
    }

    private func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        var off = 0
        while off < bytes.count {
            let w = bytes[off...].withUnsafeBytes { ptr in
                write(fd, ptr.baseAddress, bytes.count - off)
            }
            if w <= 0 { return false }
            off += w
        }
        return true
    }

    private func errnoError(_ what: String) -> NSError {
        NSError(domain: "ProxyScanBridge", code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "\(what) 失败: errno \(errno)"])
    }
}

enum ProxyScanPorts {
    static let socks5: UInt16 = 10808
    static let dnsServer = "223.5.5.5"
}
