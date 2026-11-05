import Foundation
import NetworkExtension

/// hev-socks5-tunnel C API（xcframework 静态库头文件 hev-main.h，见 doc/vpn-forwarding-design.md §9）
@_silgen_name("hev_socks5_tunnel_main_from_str")
private func hev_main_from_str(_ config: UnsafePointer<CChar>, _ len: UInt32, _ tunFd: Int32) -> Int32

@_silgen_name("hev_socks5_tunnel_quit")
private func hev_quit() -> Void

/// NEPacketTunnelFlow ↔ hev 的 fd 桥。
///
/// hev 在 Apple 平台的内置 utun 仅支持 macOS（hev-tunnel-macos.c 的 iOS 分支返回 dummy fd），
/// iOS 侧标准接法：自建 socketpair，把一端当 tun fd 交给 hev；hev 按 utun 帧格式读写——
/// 每个 IP 包前带 4 字节地址族头（本端补/剥）。
final class HevBridge {
    private var pair: (Int32, Int32) = (-1, -1)
    private var running = false
    private let pumpQueue = DispatchQueue(label: "proxyscan.hev.pump", qos: .utility, attributes: .concurrent)

    /// hev 侧收包缓冲（family header 4B + MTU）
    private static let mtu = 1500

    /// 配置：隧道内部地址与 Android 对齐（10.10.10.2/32、MTU 1500、SOCKS5 指向本地桥）
    private func makeConfig() -> String {
        """
        tunnel:
          name: utun
          mtu: \(Self.mtu)
          ipv4: 10.10.10.2
          icmp: 'off'
        socks5:
          address: 127.0.0.1
          port: \(ProxyScanPorts.socks5)
          udp: 'udp'
        misc:
          log-level: warn
        """
    }

    /// 启动 hev（阻塞调用，内部自建线程跑事件循环；本函数在后台线程调用）
    func run() -> Int32 {
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_DGRAM, 0, &fds) == 0 else { return -1 }
        pair = (fds[0], fds[1])
        running = true

        let config = makeConfig()
        let rc: Int32 = config.withCString { ptr in
            hev_main_from_str(ptr, UInt32(config.utf8.count), fds[1])
        }
        return rc
    }

    func stop() {
        running = false
        hev_quit()
        // socketpair 两端关闭：读泵解除阻塞
        if pair.0 >= 0 { close(pair.0); pair.0 = -1 }
        if pair.1 >= 0 { close(pair.1); pair.1 = -1 }
    }

    /// packetFlow → hev：IP 包前补 4 字节地址族头（utun 帧格式，小端）
    func startFlowToHevPump(_ packetFlow: NEPacketTunnelFlow) {
        pumpQueue.async {
            while self.running {
                packetFlow.readPackets { packets, protocols in
                    for (i, pkt) in packets.enumerated() {
                        var header = UInt32(protocols[i].intValue == AF_INET6 ? AF_INET6 : AF_INET)
                        var frame = withUnsafeBytes(of: &header) { Array($0) } + pkt
                        _ = frame.withUnsafeMutableBytes { ptr -> Int in
                            send(self.pair.0, ptr.baseAddress, frame.count, 0)
                        }
                    }
                }
            }
        }
    }

    /// hev → packetFlow：读 utun 帧（4B 头 + IP 包），剥头后注入
    func startHevToFlowPump(_ packetFlow: NEPacketTunnelFlow) {
        pumpQueue.async {
            var buf = [UInt8](repeating: 0, count: 4 + Self.mtu + 64)
            while self.running {
                let n = recv(self.pair.0, &buf, buf.count, 0)
                if n <= 4 {
                    if self.running { continue }
                    break
                }
                if n > 4 {
                    let family = Int(buf[0]) // 小端首字节即地址族
                    let pkt = Array(buf[4..<n])
                    if family == AF_INET {
                        packetFlow.writePackets([pkt], withProtocols: [NSNumber(value: AF_INET)])
                    } else if family == AF_INET6 {
                        packetFlow.writePackets([pkt], withProtocols: [NSNumber(value: AF_INET6)])
                    }
                }
            }
        }
    }
}
