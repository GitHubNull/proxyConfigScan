import Flutter
import Security
import UIKit

/// MethodChannel `proxy_scan/system`（与 Android SystemChannelHandler 同 API 面）。
/// iOS 不允许 App 安装/枚举用户信任证书：installCa 只把 DER 落临时目录并弹分享面板，
/// 由用户存到“文件”后经系统设置安装并完全信任。
final class SystemChannelHandler: NSObject {
    static let methodChannel = "proxy_scan/system"
    private static let fileName = "BurpSuite-CA.cer"
    private static let minCertBytes = 64
    private static let maxCertBytes = 64 * 1024

    private var channel: FlutterMethodChannel?

    func register(with messenger: FlutterBinaryMessenger) {
        let methods = FlutterMethodChannel(name: Self.methodChannel, binaryMessenger: messenger)
        methods.setMethodCallHandler { [weak self] call, result in
            guard let self else { return }
            switch call.method {
            case "caStatus":
                // iOS 无法枚举用户信任库，installed 恒为 null（UI 降级为“无法自动检测”）
                result(["supported": true,
                        "installed": NSNull(),
                        "subject": NSNull(),
                        "fingerprintSha256": NSNull()] as [String: Any])
            case "installCa": self.installCa(call: call, result: result)
            case "openAppSettings":
                self.openSettings(urlString: UIApplication.openSettingsURLString, result: result)
            case "openSecuritySettings": result(["ok": false])
            default: result(FlutterMethodNotImplemented)
            }
        }
        channel = methods
    }

    private func installCa(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let typed = args["bytes"] as? FlutterStandardTypedData else {
            result(FlutterError(code: "CA_INVALID_CERT", message: "证书内容为空或体积异常", details: nil))
            return
        }
        let data = typed.data
        guard data.count >= Self.minCertBytes, data.count <= Self.maxCertBytes,
              SecCertificateCreateWithData(nil, data as CFData) != nil else {
            result(FlutterError(code: "CA_INVALID_CERT", message: "证书解析失败", details: nil))
            return
        }
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(Self.fileName)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            result(FlutterError(code: "CA_STORAGE_FAILED",
                                message: "证书保存失败：\(error.localizedDescription)", details: nil))
            return
        }
        DispatchQueue.main.async {
            guard let host = Self.topViewController() else {
                result(FlutterError(code: "CA_INTERNAL", message: "无法打开分享面板", details: nil))
                return
            }
            let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            if let popover = controller.popoverPresentationController {
                popover.sourceView = host.view
                popover.sourceRect = CGRect(x: host.view.bounds.midX, y: host.view.bounds.midY,
                                            width: 0, height: 0)
                popover.permittedArrowDirections = []
            }
            host.present(controller, animated: true, completion: nil)
            result(["state": "shared", "fileName": Self.fileName])
        }
    }

    private func openSettings(urlString: String, result: @escaping FlutterResult) {
        guard let url = URL(string: urlString), UIApplication.shared.canOpenURL(url) else {
            result(["ok": false])
            return
        }
        UIApplication.shared.open(url, options: [:]) { ok in result(["ok": ok]) }
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        var controller = scene?.windows.first(where: \.isKeyWindow)?.rootViewController
            ?? scene?.windows.first?.rootViewController
        while let presented = controller?.presentedViewController {
            controller = presented
        }
        return controller
    }
}
