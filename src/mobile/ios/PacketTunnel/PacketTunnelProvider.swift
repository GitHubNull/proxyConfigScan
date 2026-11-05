import NetworkExtension
import Foundation

/// VPN 转发编排与状态机（iOS 侧，与 Android VpnEngine 同条款；doc/vpn-forwarding-design.md §9）。
/// 状态/统计写 App Group，Runner 轮询后经 EventChannel 推 Dart（双端事件面一致）。
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private var bridge: Socks5Bridge?
    private var hev: HevBridge?
    private var statsTimer: DispatchSourceTimer?
    private var upstream: (String, Int)?

    /// 连续失败计数（达阈值且期间零成功 → error 态，同 Android UPSTREAM_FAIL_THRESHOLD=5）
    private var consecutiveFailures = 0
    private var sawSuccess = false

    override func startTunnel(options: [String: NSObject]?,
                              completionHandler: @escaping (Error?) -> Void) {
        VpnSharedState.writeState("preparing", upstream: nil)

        // 上游来源：options（Runner startVPNTunnel 传入）→ protocol.serverAddress → App Group 待定值
        let upstreamStr = (options?["upstream"] as? String)
            ?? (protocolConfiguration as? NETunnelProviderProtocol)?.serverAddress
            ?? VpnSharedState.pendingUpstream()
        guard let parsed = Self.parseUpstream(upstreamStr ?? ""), upstreamStr != nil else {
            fail("INTERNAL", "缺少上游地址（options/serverAddress 均为空）")
            completionHandler(nil) // error 态已写共享区，由 Runner 轮询上报
            return
        }
        upstream = parsed
        VpnSharedState.writeState("preparing", upstream: upstreamStr)

        let settings = makeTunnelSettings()
        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self else { return }
            if let error {
                self.fail("TUN_OPEN_FAILED", "网络设置失败：\(error.localizedDescription)")
                completionHandler(nil)
                return
            }
            self.startEngine()
            completionHandler(nil)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason,
                             completionHandler: @escaping () -> Void) {
        VpnSharedState.writeState("stopping", upstream: upstream.map { "\($0.0):\($0.1)" })
        stopStatsTimer()
        bridge?.stop()
        bridge = nil
        hev?.stop()
        hev = nil
        VpnSharedState.writeState("idle", upstream: nil)
        completionHandler()
    }

    // MARK: - 引擎启停

    private func startEngine() {
        guard let upstream else { return }
        let b = Socks5Bridge(
            upstream: upstream,
            onSuccess: { [weak self] in
                self?.consecutiveFailures = 0
                self?.sawSuccess = true
            },
            onFailure: { [weak self] detail in
                guard let self else { return }
                self.consecutiveFailures += 1
                if !self.sawSuccess && self.consecutiveFailures >= 5 {
                    self.fail("UPSTREAM_UNREACHABLE", "连续 \(self.consecutiveFailures) 次连不上上游 \(upstream.0):\(upstream.1)（\(detail)）")
                }
            }
        )
        do {
            try b.start()
        } catch {
            fail("INTERNAL", "本地桥启动失败：\(error.localizedDescription)")
            return
        }
        bridge = b

        let h = HevBridge()
        hev = h
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let rc = h.run()
            if rc != 0 && self.bridge != nil {
                self.fail("INTERNAL", "tun2socks 启动失败 rc=\(rc)")
            }
        }
        h.startFlowToHevPump(packetFlow)
        h.startHevToFlowPump(packetFlow)

        consecutiveFailures = 0
        sawSuccess = false
        VpnSharedState.writeState("running", upstream: "\(upstream.0):\(upstream.1)")
        startStatsTimer()
    }

    private func fail(_ code: String, _ message: String) {
        stopStatsTimer()
        bridge?.stop(); bridge = nil
        hev?.stop(); hev = nil
        VpnSharedState.writeState("error", upstream: upstream.map { "\($0.0):\($0.1)" },
                                  errorCode: code, errorMessage: message)
    }

    // MARK: - 隧道网络设置（与 Android Builder 参数对齐）

    private func makeTunnelSettings() -> NETunnelNetworkSettings {
        let settings = NETunnelNetworkSettings(tunnelRemoteAddress: upstream?.0 ?? "127.0.0.1")
        let ipv4 = NEIPv4Settings(addresses: ["10.10.10.2"], subnetMasks: ["255.255.255.0"])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = ipv4
        let dns = NEDNSSettings(servers: [ProxyScanPorts.dnsServer])
        dns.matchDomains = [""] // 全部域名走该 DNS
        settings.dnsSettings = dns
        settings.mtu = 1500
        return settings
    }

    // MARK: - 统计帧（1s，写共享区由 Runner 转发）

    private func startStatsTimer() {
        stopStatsTimer()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 1, repeating: 1.0)
        timer.setEventHandler { [weak self] in
            guard let self, let b = self.bridge else { return }
            VpnSharedState.writeStats(
                tx: b.stats.tx, rx: b.stats.rx, active: b.stats.active,
                dns: b.stats.dns, udpDropped: b.stats.udpDropped
            )
        }
        timer.resume()
        statsTimer = timer
    }

    private func stopStatsTimer() {
        statsTimer?.cancel()
        statsTimer = nil
    }

    private static func parseUpstream(_ value: String) -> (String, Int)? {
        let idx = value.lastIndex(of: ":") ?? value.endIndex
        let host = String(value[value.startIndex..<idx])
        let portStr = idx < value.endIndex ? String(value[value.index(after: idx)...]) : ""
        guard !host.isEmpty, let port = Int(portStr), port > 0, port <= 65535 else { return nil }
        return (host, port)
    }
}
