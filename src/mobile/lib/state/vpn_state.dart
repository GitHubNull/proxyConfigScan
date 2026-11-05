import 'package:flutter_riverpod/flutter_riverpod.dart';

/// VPN 状态机（M2 接入原生通道后充实；本期仅状态骨架）。
/// 状态迁移见 doc/vpn-forwarding-design.md §3.3。
enum VpnLifecycle { idle, preparing, running, stopping, error }

class VpnSnapshot {
  const VpnSnapshot({
    required this.lifecycle,
    this.upstream,
    this.error,
  });

  final VpnLifecycle lifecycle;
  final String? upstream;
  final String? error;

  bool get isRunning => lifecycle == VpnLifecycle.running;
}

class VpnNotifier extends Notifier<VpnSnapshot> {
  @override
  VpnSnapshot build() => const VpnSnapshot(lifecycle: VpnLifecycle.idle);

  // M2：start/stop/status/clearError 经 MethodChannel 'proxy_scan/vpn' 下发。
}

final vpnProvider = NotifierProvider<VpnNotifier, VpnSnapshot>(VpnNotifier.new);
