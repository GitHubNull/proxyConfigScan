import 'package:flutter/services.dart';

import '../util/proxy_uri_validator.dart';
import 'proxy_engine.dart';

/// 平台通道实现（Android/iOS 同面）：MethodChannel `proxy_scan/vpn` + EventChannel `proxy_scan/vpn_events`
/// （doc/vpn-forwarding-design.md §3，双端同面）。
class ProxyEngineChannels implements ProxyEngine {
  static const MethodChannel _method = MethodChannel('proxy_scan/vpn');
  static const EventChannel _events = EventChannel('proxy_scan/vpn_events');

  @override
  Future<void> start(ProxyConfig config) async {
    try {
      await _method.invokeMethod<Map<dynamic, dynamic>>('start', {
        'host': config.host,
        'port': config.port,
      });
    } on PlatformException catch (e) {
      throw VpnEngineException(e.code, e.message ?? '未知错误');
    }
  }

  @override
  Future<void> stop() async {
    await _method.invokeMethod<Map<dynamic, dynamic>>('stop');
  }

  @override
  Future<VpnSnapshot> status() async {
    final raw = await _method.invokeMethod<Map<dynamic, dynamic>>('status');
    if (raw == null) {
      return const VpnSnapshot(lifecycle: VpnLifecycle.idle);
    }
    return VpnSnapshot(
      lifecycle: _parseLifecycle(raw['state'] as String?),
      upstream: raw['upstream'] as String?,
      errorCode: raw['error'] as String?,
    );
  }

  @override
  Future<bool> prepare() async {
    final raw = await _method.invokeMethod<Map<dynamic, dynamic>>('prepare');
    return raw?['granted'] == true;
  }

  @override
  Future<void> clearError() async {
    await _method.invokeMethod<Map<dynamic, dynamic>>('clearError');
  }

  @override
  Stream<VpnNativeEvent> get events => _events.receiveBroadcastStream().map(_parseEvent);

  VpnNativeEvent _parseEvent(dynamic raw) {
    final map = Map<String, dynamic>.from(raw as Map);
    switch (map['type'] as String?) {
      case 'state':
        return VpnStateEvent(
          lifecycle: _parseLifecycle(map['state'] as String?),
          upstream: map['upstream'] as String?,
        );
      case 'stats':
        return VpnStatsEvent(
          txBytes: (map['txBytes'] as num?)?.toInt() ?? 0,
          rxBytes: (map['rxBytes'] as num?)?.toInt() ?? 0,
          activeConnections: (map['activeConnections'] as num?)?.toInt() ?? 0,
          dnsQueries: (map['dnsQueries'] as num?)?.toInt() ?? 0,
          udpDropped: (map['udpDropped'] as num?)?.toInt() ?? 0,
        );
      case 'error':
        return VpnErrorEvent(
          code: map['code'] as String? ?? 'INTERNAL',
          message: map['message'] as String? ?? '未知错误',
        );
      default:
        return const VpnStateEvent(lifecycle: VpnLifecycle.idle);
    }
  }

  VpnLifecycle _parseLifecycle(String? raw) => switch (raw) {
        'preparing' => VpnLifecycle.preparing,
        'running' => VpnLifecycle.running,
        'stopping' => VpnLifecycle.stopping,
        'error' => VpnLifecycle.error,
        _ => VpnLifecycle.idle,
      };
}
