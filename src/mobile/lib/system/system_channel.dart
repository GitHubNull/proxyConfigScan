import 'package:flutter/services.dart';

/// 证书状态。`installed == null` 表示平台无法枚举（iOS）。
class CaStatus {
  const CaStatus({
    required this.supported,
    this.installed,
    this.subject,
    this.fingerprintSha256,
  });

  final bool supported;
  final bool? installed;
  final String? subject;
  final String? fingerprintSha256;
}

/// 安装动作的原生结果：`launched`（已弹系统安装器）/ `saved` / `shared`。
class CaInstallResult {
  const CaInstallResult({required this.state, this.fileName});

  final String state;
  final String? fileName;
}

class CaException implements Exception {
  const CaException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => message;
}

/// 平台系统能力通道 `proxy_scan/system`（Android/iOS 同面）。
class SystemChannel {
  SystemChannel._();

  static const MethodChannel _channel = MethodChannel('proxy_scan/system');

  static Future<CaStatus> caStatus() async {
    try {
      final raw =
          await _channel.invokeMethod<Map<dynamic, dynamic>>('caStatus');
      if (raw == null) {
        throw const CaException('CA_INTERNAL', '证书状态查询无返回');
      }
      return CaStatus(
        supported: raw['supported'] as bool? ?? false,
        installed: raw['installed'] as bool?,
        subject: raw['subject'] as String?,
        fingerprintSha256: raw['fingerprintSha256'] as String?,
      );
    } on PlatformException catch (e) {
      throw CaException(e.code, e.message ?? '证书状态查询失败');
    } on MissingPluginException {
      throw const CaException('CA_INTERNAL', '当前平台未实现证书检测');
    }
  }

  static Future<CaInstallResult> installCa(
    Uint8List bytes, {
    required String name,
  }) async {
    try {
      final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'installCa',
        {'bytes': bytes, 'name': name},
      );
      if (raw == null) {
        throw const CaException('CA_INTERNAL', '证书安装无返回');
      }
      return CaInstallResult(
        state: raw['state'] as String? ?? 'saved',
        fileName: raw['fileName'] as String?,
      );
    } on PlatformException catch (e) {
      throw CaException(e.code, e.message ?? '证书安装失败');
    } on MissingPluginException {
      throw const CaException('CA_UNSUPPORTED', '当前平台未实现证书安装');
    }
  }

  /// 打开本应用的系统设置页（相机权限等）。返回 false 表示原生端未响应。
  static Future<bool> openAppSettings() async {
    try {
      await _channel.invokeMethod<void>('openAppSettings');
      return true;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 打开系统「安全」设置（Android CA 安装入口）。iOS 无对应入口时返回 false。
  static Future<bool> openSecuritySettings() async {
    try {
      final raw = await _channel
          .invokeMethod<Map<dynamic, dynamic>>('openSecuritySettings');
      return raw?['ok'] == true;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}
