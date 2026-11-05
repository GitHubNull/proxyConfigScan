import '../util/proxy_uri_validator.dart';

/// 原生 VPN 引擎抽象。Android 走 MethodChannel 'proxy_scan/vpn'（设计文档 §3），
/// iOS（M5）实现同名通道同 API 面，Flutter 侧无感切换。
abstract class ProxyEngine {
  Future<void> start(ProxyConfig config);

  Future<void> stop();

  /// 冷启动/重建时同步快照：`{state, upstream, error}`
  Future<VpnSnapshot> status();

  /// 仅弹系统 VPN 授权框预热；返回是否已授权
  Future<bool> prepare();

  Future<void> clearError();

  /// 原生事件流：state 迁移帧 + 1s 统计帧 + error 帧
  Stream<VpnNativeEvent> get events;
}

/// 状态迁移帧：`{type:state, state, upstream}`
class VpnStateEvent extends VpnNativeEvent {
  const VpnStateEvent({required this.lifecycle, this.upstream});

  final VpnLifecycle lifecycle;
  final String? upstream;
}

/// 统计帧：`{type:stats, txBytes, rxBytes, activeConnections, dnsQueries, udpDropped}`
class VpnStatsEvent extends VpnNativeEvent {
  const VpnStatsEvent({
    required this.txBytes,
    required this.rxBytes,
    required this.activeConnections,
    required this.dnsQueries,
    required this.udpDropped,
  });

  final int txBytes;
  final int rxBytes;
  final int activeConnections;
  final int dnsQueries;
  final int udpDropped;
}

/// 错误帧：`{type:error, code, message}`（code 见设计文档 §3.4）
class VpnErrorEvent extends VpnNativeEvent {
  const VpnErrorEvent({required this.code, required this.message});

  final String code;
  final String message;
}

sealed class VpnNativeEvent {
  const VpnNativeEvent();
}

/// status() 返回值
class VpnSnapshot {
  const VpnSnapshot({required this.lifecycle, this.upstream, this.errorCode});

  final VpnLifecycle lifecycle;
  final String? upstream;
  final String? errorCode;
}

enum VpnLifecycle { idle, preparing, running, stopping, error }

/// start() 被原生拒绝时抛出的业务异常（如用户拒绝 VPN 授权）
class VpnEngineException implements Exception {
  const VpnEngineException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'VpnEngineException($code): $message';
}
