import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/scan_state.dart';
import '../../state/vpn_state.dart';

/// 状态页：VPN 运行状态 + 最近一次扫码结果（M2 接入原生后展示实时状态与流量）。
class StatusPage extends ConsumerWidget {
  const StatusPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final vpn = ref.watch(vpnProvider);
    final scan = ref.watch(scanProvider);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: ListTile(
            leading: Icon(
              vpn.isRunning ? Icons.vpn_lock : Icons.vpn_lock_outlined,
              color: vpn.isRunning ? Colors.green : Colors.grey,
            ),
            title: const Text('代理转发'),
            subtitle: Text(switch (vpn.lifecycle) {
              VpnLifecycle.idle => '未启动（M2 接入 VPN 转发）',
              VpnLifecycle.running => '运行中 · ${vpn.upstream}',
              VpnLifecycle.error => '错误：${vpn.error}',
              _ => vpn.lifecycle.name,
            }),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: ListTile(
            leading: const Icon(Icons.qr_code_2),
            title: const Text('最近一次扫码'),
            subtitle: Text(switch (scan) {
              ScanSuccess(:final config) => config.upstream,
              ScanFailure(:final message) => '失败：$message',
              _ => '暂无',
            }),
          ),
        ),
      ],
    );
  }
}
