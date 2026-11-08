import Foundation

/// extension 与 container（Runner）经 App Group 共享 VPN 状态/统计。
/// 帧格式与 Android EventChannel 1s 帧对齐（doc/vpn-forwarding-design.md §3/§10）。
enum VpnSharedState {
    /// 侧载签名（AltStore/AltServer）会把 App Group 重写成 team 后缀变体；硬编码原名
    /// 会拿到 nil defaults 双端静默失联。embedded.mobileprovision 的 Entitlements
    /// 与签名 entitlements 一致，是进程实际被授权组的 ground truth。
    static let suiteName: String = {
        if let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
           let data = try? Data(contentsOf: url),
           let text = String(data: data, encoding: .isoLatin1),
           let start = text.range(of: "<?xml"),
           let end = text.range(of: "</plist>") {
            let xml = String(text[start.lowerBound...end.upperBound])
            if let plistData = xml.data(using: .isoLatin1),
               let plist = try? PropertyListSerialization.propertyList(from: plistData) as? [String: Any],
               let groups = (plist["Entitlements"] as? [String: Any])?["com.apple.security.application-groups"] as? [String],
               let first = groups.first {
                return first
            }
        }
        return "group.com.proxyscan.proxyconfigscan"
    }()

    // 键名
    private enum Key {
        static let state = "vpn.state"           // idle/preparing/running/stopping/error
        static let upstream = "vpn.upstream"     // host:port
        static let errorCode = "vpn.errorCode"
        static let errorMessage = "vpn.errorMessage"
        static let txBytes = "vpn.txBytes"
        static let rxBytes = "vpn.rxBytes"
        static let activeConnections = "vpn.activeConnections"
        static let dnsQueries = "vpn.dnsQueries"
        static let udpDropped = "vpn.udpDropped"
        static let updatedAt = "vpn.updatedAt"   // 扩展心跳，container 据此判断扩展存活
    }

    private static func defaults() -> UserDefaults? {
        UserDefaults(suiteName: suiteName)
    }

    /// Runner 启停前写入上游；extension startTunnel 读取。
    static func setPendingUpstream(_ upstream: String) {
        defaults()?.set(upstream, forKey: "vpn.pendingUpstream")
    }

    static func pendingUpstream() -> String? {
        defaults()?.string(forKey: "vpn.pendingUpstream")
    }

    // MARK: - 状态写入（extension 侧）

    static func writeState(_ state: String, upstream: String?, errorCode: String? = nil, errorMessage: String? = nil) {
        guard let d = defaults() else { return }
        d.set(state, forKey: Key.state)
        d.set(upstream, forKey: Key.upstream)
        d.set(errorCode, forKey: Key.errorCode)
        d.set(errorMessage, forKey: Key.errorMessage)
        d.set(Date().timeIntervalSince1970, forKey: Key.updatedAt)
    }

    static func writeStats(tx: Int64, rx: Int64, active: Int, dns: Int64, udpDropped: Int64) {
        guard let d = defaults() else { return }
        d.set(tx, forKey: Key.txBytes)
        d.set(rx, forKey: Key.rxBytes)
        d.set(active, forKey: Key.activeConnections)
        d.set(dns, forKey: Key.dnsQueries)
        d.set(udpDropped, forKey: Key.udpDropped)
        d.set(Date().timeIntervalSince1970, forKey: Key.updatedAt)
    }

    // MARK: - 读取（Runner 侧轮询）

    struct Snapshot {
        var state: String
        var upstream: String?
        var errorCode: String?
        var errorMessage: String?
        var txBytes: Int64
        var rxBytes: Int64
        var activeConnections: Int
        var dnsQueries: Int64
        var udpDropped: Int64
        var updatedAt: TimeInterval
    }

    static func snapshot() -> Snapshot {
        let d = defaults()
        return Snapshot(
            state: d?.string(forKey: Key.state) ?? "idle",
            upstream: d?.string(forKey: Key.upstream),
            errorCode: d?.string(forKey: Key.errorCode),
            errorMessage: d?.string(forKey: Key.errorMessage),
            txBytes: d?.object(forKey: Key.txBytes) as? Int64 ?? 0,
            rxBytes: d?.object(forKey: Key.rxBytes) as? Int64 ?? 0,
            activeConnections: d?.object(forKey: Key.activeConnections) as? Int ?? 0,
            dnsQueries: d?.object(forKey: Key.dnsQueries) as? Int64 ?? 0,
            udpDropped: d?.object(forKey: Key.udpDropped) as? Int64 ?? 0,
            updatedAt: d?.object(forKey: Key.updatedAt) as? TimeInterval ?? 0
        )
    }
}
