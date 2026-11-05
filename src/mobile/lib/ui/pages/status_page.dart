import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/scan_state.dart';
import '../../state/vpn_state.dart';
import '../../util/proxy_uri_validator.dart';
import '../../vpn/proxy_engine.dart';

/// 状态页：VPN 状态机 + 实时流量统计 + 启停控制。
class StatusPage extends ConsumerWidget {
  const StatusPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncSnapshot = ref.watch(vpnSnapshotProvider);
    final vpn = asyncSnapshot.value ??
        ref.watch(vpnControllerProvider).current;
    final scan = ref.watch(scanProvider);
    final controller = ref.watch(vpnControllerProvider);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: ListTile(
            leading: Icon(
              vpn.isRunning ? Icons.vpn_lock : Icons.vpn_lock_outlined,
              color: switch (vpn.lifecycle) {
                VpnLifecycle.running => Colors.green,
                VpnLifecycle.error => Colors.red,
                VpnLifecycle.preparing || VpnLifecycle.stopping => Colors.orange,
                VpnLifecycle.idle => Colors.grey,
              },
            ),
            title: const Text('代理转发'),
            subtitle: Text(switch (vpn.lifecycle) {
              VpnLifecycle.idle => '未启动',
              VpnLifecycle.preparing => '正在启动…',
              VpnLifecycle.running => '运行中 · ${vpn.upstream}',
              VpnLifecycle.stopping => '正在停止…',
              VpnLifecycle.error => vpnErrorText(vpn.errorCode, vpn.errorMessage),
            }),
            trailing: switch (vpn.lifecycle) {
              VpnLifecycle.idle => FilledButton(
                  onPressed: switch (scan) {
                    ScanSuccess(:final config) => () => _start(context, ref, config),
                    _ => null,
                  },
                  child: const Text('启动'),
                ),
              VpnLifecycle.running => OutlinedButton(
                  onPressed: () => controller.stop(),
                  child: const Text('停止'),
                ),
              VpnLifecycle.error => TextButton(
                  onPressed: () => controller.clearError(),
                  child: const Text('清除错误'),
                ),
              _ => const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            },
          ),
        ),
        if (vpn.lifecycle == VpnLifecycle.idle && scan is! ScanSuccess)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text(
              '提示：先在扫码页解析一个代理配置，再回这里启动。',
              style: TextStyle(color: Colors.grey, fontSize: 13),
            ),
          ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('流量统计', style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 12),
                _StatsRow(
                  label: '发送 / 接收',
                  value:
                      '${_formatBytes(vpn.stats.txBytes)} / ${_formatBytes(vpn.stats.rxBytes)}',
                ),
                _StatsRow(
                  label: '活动连接',
                  value: '${vpn.stats.activeConnections}',
                ),
                _StatsRow(label: 'DNS 查询', value: '${vpn.stats.dnsQueries}'),
                _StatsRow(label: '丢弃 UDP', value: '${vpn.stats.udpDropped}'),
              ],
            ),
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

  Future<void> _start(BuildContext context, WidgetRef ref, ProxyConfig config) async {
    final controller = ref.read(vpnControllerProvider);
    try {
      await controller.start(config);
    } on VpnEngineException catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(vpnErrorText(e.code, e.message))),
        );
      }
    }
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }
}

class _StatsRow extends StatelessWidget {
  const _StatsRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: Colors.grey)),
          Text(value),
        ],
      ),
    );
  }
}
