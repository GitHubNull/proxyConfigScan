import os.log
import Foundation

/// UDP ASSOCIATE 转发（RFC 1928；仅放行目标端口 53 → 223.5.5.5，其余丢弃计数；从 Socks5Bridge 拆出控制单文件行数）
extension Socks5Bridge {
    
        func handleUdpAssociate(_ clientFd: Int32, target: (host: String, port: Int, raw: [UInt8])) {
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
}
