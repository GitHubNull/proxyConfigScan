import 'dart:core';

/// 二维码解析结果。
class ProxyConfig {
  const ProxyConfig({
    required this.host,
    required this.port,
    required this.isLanHost,
  });

  /// 来自历史记录 / 最近扫码等已校验来源时的回填入口。
  factory ProxyConfig.fromHostPort(String host, int port) => ProxyConfig(
        host: host,
        port: port,
        isLanHost: ProxyUriValidator.isLanHost(host),
      );

  final String host;
  final int port;

  /// host 是否处于私网保留段（10/8、172.16/12、192.168/16、169.254/16、127/8）
  final bool isLanHost;

  /// host 是否为回环（127.0.0.1/::1/localhost）——二维码指向手机本机，
  /// 代理服务实际不在手机上，必连不上，需与 isLanHost 区分提示
  bool get isLoopbackHost => ProxyUriValidator.isLoopback(host);

  String get upstream => '$host:$port';
}

/// 解析失败时的中文错误文案。
class ProxyParseException implements Exception {
  const ProxyParseException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 代理配置 URI 校验器。
///
/// 格式约定见项目 doc/qr-format-spec.md：标准 URI `http://host:port`，缺省端口 8080。
class ProxyUriValidator {
  ProxyUriValidator._();

  static const int defaultPort = 8080;

  /// 按规范解析并校验二维码载荷。
  ///
  /// [raw] 为二维码原始文本。容错：裸 `host:port`（缺 scheme）自动补 `http://` 重试一次。
  /// 成功返回 [ProxyConfig]；失败抛 [ProxyParseException]（中文文案）。
  static ProxyConfig parse(String raw) {
    final text = raw.trim();
    if (text.isEmpty) {
      throw const ProxyParseException('二维码内容为空');
    }

    // 裸 host:port 容错（仅限不含 scheme 的输入，避免二次拼接出伪合法 URI）
    Uri? uri = _tryParse(text);
    uri ??= text.contains('://') ? null : _tryParse('http://$text');
    if (uri == null) {
      // Uri.parse 对越界端口直接抛 FormatException，这里补一条明确的端口报错
      final portMatch = RegExp(r'^[^:]+:\/\/?[^/?#]*:(\d+)(?=[/?#]|$)').firstMatch(text);
      if (portMatch != null) {
        final value = int.tryParse(portMatch.group(1)!);
        if (value == null || value < 1 || value > 65535) {
          throw const ProxyParseException('端口不合法（应为 1-65535）');
        }
      }
      throw const ProxyParseException('无法识别的二维码格式');
    }

    final scheme = uri.scheme.toLowerCase();
    if (scheme != 'http') {
      if (scheme == 'https' || scheme == 'socks5') {
        throw const ProxyParseException('暂不支持该类型，目前仅支持 http 代理');
      }
      throw const ProxyParseException('无法识别的二维码格式');
    }
    if (uri.hasAuthority && uri.userInfo.isNotEmpty) {
      throw const ProxyParseException('二维码格式不合法：不允许包含用户信息');
    }

    final host = _validateHost(uri);
    final port = _validatePort(uri);

    return ProxyConfig(host: host, port: port, isLanHost: isLanHost(host));
  }

  static Uri? _tryParse(String text) {
    try {
      final uri = Uri.parse(text);
      // Uri.parse 对不少非法输入不报错而是返回残缺结果，必须校验 scheme/host 存在
      if (uri.scheme.isEmpty || uri.host.isEmpty) return null;
      return uri;
    } on FormatException {
      return null;
    }
  }

  static String _validateHost(Uri uri) {
    if (uri.host.isEmpty) {
      throw const ProxyParseException('二维码缺少代理地址');
    }
    final host = uri.host;
    if (host.contains(':')) {
      // IPv6：Dart 的 uri.host 已去方括号，冒号即 IPv6
      if (!_isValidIpv6(host)) {
        throw const ProxyParseException('IPv6 地址不合法');
      }
      return host;
    }
    if (_looksLikeIpv4(host)) {
      if (!_isValidIpv4(host)) {
        throw const ProxyParseException('IP 地址不合法');
      }
      return host;
    }
    // 纯数字点分但不是合法 IPv4（如 192.168.1、1.2.3.4.5），按 IP 拒绝而非降级当域名
    if (RegExp(r'^[0-9.]+$').hasMatch(host)) {
      throw const ProxyParseException('IP 地址不合法');
    }
    if (!_isValidDomain(host)) {
      throw const ProxyParseException('域名不合法');
    }
    return host;
  }

  static int _validatePort(Uri uri) {
    final portText = uri.hasPort ? uri.port.toString() : '';
    if (portText.isEmpty) {
      return defaultPort;
    }
    final port = int.tryParse(portText);
    if (port == null || port < 1 || port > 65535) {
      throw const ProxyParseException('端口不合法（应为 1-65535）');
    }
    return port;
  }

  static bool _looksLikeIpv4(String host) {
    return RegExp(r'^\d+\.\d+\.\d+\.\d+$').hasMatch(host);
  }

  static bool _isValidIpv4(String host) {
    final parts = host.split('.');
    if (parts.length != 4) return false;
    for (final part in parts) {
      if (part.isEmpty || part.length > 3) return false;
      if (!RegExp(r'^\d+$').hasMatch(part)) return false;
      // 拒绝前导零（01.2.3.4 歧义）
      if (part.length > 1 && part.startsWith('0')) return false;
      final value = int.parse(part);
      if (value > 255) return false;
    }
    return true;
  }

  static bool _isValidIpv6(String host) {
    // 交由 Uri 解析成功即基本可信，这里只做形状复核
    if (host.length > 45) return false;
    final groups = host.split(':');
    final hasCompressed = host.contains('::');
    final expectedGroups = hasCompressed ? 8 : 7;
    if (!hasCompressed && groups.length != expectedGroups) return false;
    for (final group in groups) {
      if (group.isEmpty) continue;
      if (!RegExp(r'^[0-9a-fA-F]{1,4}$').hasMatch(group)) return false;
    }
    return true;
  }

  static bool _isValidDomain(String host) {
    if (host.length > 253) return false;
    final labels = host.split('.');
    for (final label in labels) {
      if (label.isEmpty || label.length > 63) return false;
      if (label.startsWith('-') || label.endsWith('-')) return false;
      if (!RegExp(r'^[a-zA-Z0-9-]+$').hasMatch(label)) return false;
    }
    return true;
  }

  /// host 是否为回环地址（历史记录复用时回填提示位也用同一口径；
  /// 与 Burp 插件 ProxyListenerDetector.isLoopbackAddress 判定一致）
  static bool isLoopback(String host) {
    final lower = host.toLowerCase();
    return lower == 'localhost' ||
        lower == '::1' ||
        lower == '0:0:0:0:0:0:0:1' ||
        lower.startsWith('127.');
  }

  /// host 是否处于私网保留段（历史记录复用时回填提示位也用同一口径）
  static bool isLanHost(String host) {
    if (_looksLikeIpv4(host) && _isValidIpv4(host)) {
      final parts = host.split('.').map(int.parse).toList();
      final a = parts[0];
      if (a == 10) return true;
      if (a == 127) return true;
      if (a == 172 && parts[1] >= 16 && parts[1] <= 31) return true;
      if (a == 192 && parts[1] == 168) return true;
      if (a == 169 && parts[1] == 254) return true;
      return false;
    }
    if (host.contains(':')) return false; // IPv6 一律按公网提示
    final lower = host.toLowerCase();
    return lower == 'localhost' || lower.endsWith('.lan') || lower.endsWith('.local');
  }
}
