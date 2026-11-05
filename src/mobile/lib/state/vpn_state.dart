import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../util/proxy_uri_validator.dart';
import '../vpn/proxy_engine.dart';
import '../vpn/proxy_engine_channels.dart';
import 'history_state.dart';

/// VPN 聚合快照：状态机 + 上游 + 错误 + 最新统计帧
class VpnSnapshot {
  const VpnSnapshot({
    required this.lifecycle,
    this.upstream,
    this.errorCode,
    this.errorMessage,
    this.stats = const VpnStatsEvent(
      txBytes: 0,
      rxBytes: 0,
      activeConnections: 0,
      dnsQueries: 0,
      udpDropped: 0,
    ),
  });

  final VpnLifecycle lifecycle;
  final String? upstream;
  final String? errorCode;
  final String? errorMessage;
  final VpnStatsEvent stats;

  bool get isRunning => lifecycle == VpnLifecycle.running;
}

/// 引擎控制器：封装 [ProxyEngine]，把原生事件流折叠成 [VpnSnapshot]。
class VpnController {
  VpnController(this._engine, {void Function(ProxyConfig config)? onStart})
      : _onStart = onStart;

  final ProxyEngine _engine;
  final void Function(ProxyConfig config)? _onStart;
  final StreamController<VpnSnapshot> _controller =
      StreamController<VpnSnapshot>.broadcast();
  StreamSubscription<VpnNativeEvent>? _eventsSub;

  VpnSnapshot _current = const VpnSnapshot(lifecycle: VpnLifecycle.idle);

  VpnSnapshot get current => _current;

  Stream<VpnSnapshot> get stream => _controller.stream;

  Future<void> init() async {
    await _eventsSub?.cancel();
    _eventsSub = _engine.events.listen(_onEvent);
    final snapshot = await _engine.status();
    _current = VpnSnapshot(
      lifecycle: snapshot.lifecycle,
      upstream: snapshot.upstream,
      errorCode: snapshot.errorCode,
      stats: _current.stats,
    );
    _controller.add(_current);
  }

  Future<void> start(ProxyConfig config) async {
    await _engine.start(config);
    // 启动成功后刷新历史记录的最近使用时间（同 host:port 幂等）
    _onStart?.call(config);
  }

  Future<void> stop() => _engine.stop();

  Future<bool> prepare() => _engine.prepare();

  Future<void> clearError() => _engine.clearError();

  void _onEvent(VpnNativeEvent event) {
    final next = switch (event) {
      VpnStateEvent(:final lifecycle, :final upstream) => VpnSnapshot(
          lifecycle: lifecycle,
          upstream: upstream ?? _current.upstream,
          errorCode: _current.errorCode,
          errorMessage: _current.errorMessage,
          stats: _current.stats,
        ),
      VpnStatsEvent() => VpnSnapshot(
          lifecycle: _current.lifecycle,
          upstream: _current.upstream,
          errorCode: _current.errorCode,
          errorMessage: _current.errorMessage,
          stats: event,
        ),
      VpnErrorEvent(:final code, :final message) => VpnSnapshot(
          lifecycle: VpnLifecycle.error,
          upstream: _current.upstream,
          errorCode: code,
          errorMessage: message,
          stats: _current.stats,
        ),
    };
    _current = next;
    _controller.add(next);
  }

  Future<void> dispose() async {
    await _eventsSub?.cancel();
    await _controller.close();
  }
}

final vpnControllerProvider = Provider<VpnController>((ref) {
  final controller = VpnController(
    ProxyEngineChannels(),
    onStart: (config) => ref.read(historyProvider.notifier).touch(config),
  );
  controller.init();
  ref.onDispose(controller.dispose);
  return controller;
});

final vpnSnapshotProvider = StreamProvider<VpnSnapshot>((ref) {
  return ref.watch(vpnControllerProvider).stream;
});

/// 错误码 → 中文文案（设计文档 §3.4）
String vpnErrorText(String? code, String? message) => switch (code) {
      'USER_DECLINED_CONSENT' => '已取消 VPN 授权，代理未启动',
      'UPSTREAM_UNREACHABLE' => '连不上代理上游（$message）',
      'TUNNEL_HANDSHAKE_FAILED' => '代理隧道握手失败（$message）',
      'TUN_OPEN_FAILED' => 'VPN 通道建立失败，请重试',
      'INTERNAL' => '内部错误（$message）',
      null => '未知错误',
      _ => '$code（$message）',
    };
