import Flutter
import NetworkExtension
import UIKit

/// Method/EventChannel 桥（iOS 侧，与 Android VpnChannelHandler 同 API 面，
/// doc/vpn-forwarding-design.md §3）。启停经 NEVPNManager + PacketTunnel extension；
/// 状态/统计由 extension 写 App Group，本处 1s 轮询转 EventChannel。
final class VpnChannelHandler: NSObject {
    static let methodChannel = "proxy_scan/vpn"
    static let eventChannel = "proxy_scan/vpn_events"
    static let extensionBundleId = "com.proxyscan.proxyConfigScan.PacketTunnel"

    private var eventSink: FlutterEventSink?
    private var pollTimer: Timer?
    private var lastPushedState = ""
    private var lastPushedError: String?

    func register(with messenger: FlutterBinaryMessenger) {
        let methods = FlutterMethodChannel(name: Self.methodChannel, binaryMessenger: messenger)
        methods.setMethodCallHandler { [weak self] call, result in
            guard let self else { return }
            switch call.method {
            case "start": self.start(call: call, result: result)
            case "stop": self.stop(result: result)
            case "status": self.status(result: result)
            case "prepare": result(["granted": true]) // iOS 首次启动由系统弹授权，无 prepare 概念
            case "clearError": self.clearError(result: result)
            default: result(FlutterMethodNotImplemented)
            }
        }

        let events = FlutterEventChannel(name: Self.eventChannel, binaryMessenger: messenger)
        events.setStreamHandler(self)
    }

    // MARK: - start/stop

    private func start(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let host = args["host"] as? String, let port = args["port"] as? Int else {
            result(FlutterError(code: "INTERNAL", message: "参数缺失 host/port", details: nil))
            return
        }
        let upstream = "\(host):\(port)"
        VpnSharedState.setPendingUpstream(upstream)

        NETunnelProviderManager.loadAllFromPreferences { managers, error in
            if let error {
                result(FlutterError(code: "INTERNAL", message: "读取 VPN 配置失败：\(error.localizedDescription)", details: nil))
                return
            }
            let manager = managers?.first ?? NETunnelProviderManager()
            let proto = NETunnelProviderProtocol()
            proto.providerBundleIdentifier = Self.extensionBundleId
            proto.serverAddress = upstream
            manager.protocolConfiguration = proto
            manager.isEnabled = true
            manager.localizedDescription = "ProxyScan 代理转发"
            manager.saveToPreferences { error in
                if let error {
                    result(FlutterError(code: "INTERNAL", message: "保存 VPN 配置失败：\(error.localizedDescription)", details: nil))
                    return
                }
                do {
                    try manager.connection.startVPNTunnel(options: ["upstream": upstream as NSObject])
                } catch {
                    result(FlutterError(code: "INTERNAL", message: "启动隧道失败：\(error.localizedDescription)", details: nil))
                    return
                }
                // 轮询共享状态：running 成功 / error 透传错误码
                self.waitForState { snap in
                    if snap.state == "error" {
                        result(FlutterError(code: snap.errorCode ?? "INTERNAL",
                                            message: snap.errorMessage ?? "未知错误", details: nil))
                    } else {
                        result(["state": snap.state, "upstream": snap.upstream ?? NSNull()] as [String: Any])
                    }
                }
            }
        }
    }

    private func stop(result: @escaping FlutterResult) {
        NETunnelProviderManager.loadAllFromPreferences { managers, _ in
            guard let manager = managers?.first else {
                result(["state": "idle"] as [String: Any])
                return
            }
            manager.connection.stopVPNTunnel()
            self.waitForState { snap in
                result(["state": snap.state, "upstream": snap.upstream ?? NSNull()] as [String: Any])
            }
        }
    }

    private func status(result: @escaping FlutterResult) {
        let snap = VpnSharedState.snapshot()
        result(["state": snap.state, "upstream": snap.upstream ?? NSNull(), "error": snap.errorCode ?? NSNull()] as [String: Any])
    }

    private func clearError(result: @escaping FlutterResult) {
        VpnSharedState.writeState("idle", upstream: nil)
        result(nil)
    }

    /// 轮询共享状态直到非 preparing/stopping 或超时（10s）
    private func waitForState(_ done: @escaping (VpnSharedState.Snapshot) -> Void) {
        var attempts = 0
        func poll() {
            let snap = VpnSharedState.snapshot()
            let settled = ["running", "error", "idle"].contains(snap.state)
            if settled || attempts >= 40 {
                done(snap)
                return
            }
            attempts += 1
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) { poll() }
        }
        poll()
    }

    // MARK: - EventChannel：1s 轮询共享区推帧（与 Android 1s 帧同形状）

    private func startPolling() {
        stopPolling()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self, let sink = self.eventSink else { return }
            let snap = VpnSharedState.snapshot()

            if snap.state != self.lastPushedState || snap.upstream != nil {
                self.lastPushedState = snap.state
                sink(["type": "state", "state": snap.state, "upstream": snap.upstream ?? NSNull()] as [String: Any])
            }
            sink(["type": "stats",
                  "txBytes": snap.txBytes, "rxBytes": snap.rxBytes,
                  "activeConnections": snap.activeConnections,
                  "dnsQueries": snap.dnsQueries, "udpDropped": snap.udpDropped] as [String: Any])
            if snap.state == "error", let code = snap.errorCode, code != self.lastPushedError {
                self.lastPushedError = code
                sink(["type": "error", "code": code, "message": snap.errorMessage ?? "未知错误"] as [String: Any])
            }
            if snap.state != "error" { self.lastPushedError = nil }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }
}

extension VpnChannelHandler: FlutterStreamHandler {
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        eventSink = events
        startPolling()
        // 补发当前状态，对齐 Android attachSink 立即推帧
        let snap = VpnSharedState.snapshot()
        events(["type": "state", "state": snap.state, "upstream": snap.upstream ?? NSNull()] as [String: Any])
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        stopPolling()
        return nil
    }
}
