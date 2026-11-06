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
    final batteryExempted = ref.watch(batteryExemptedProvider).value ?? true;
    final action = ref.watch(vpnActionProvider);

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
              VpnLifecycle.idle => FilledButton.icon(
                  onPressed: action == VpnAction.none
                      ? switch (scan) {
                          ScanSuccess(:final config) =>
                            () => _start(context, ref, config),
                          _ => null,
                        }
                      : null,
                  icon: action == VpnAction.starting
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.play_arrow),
                  label: Text(action == VpnAction.starting ? '正在启动…' : '启动'),
                ),
              VpnLifecycle.running => OutlinedButton(
                  onPressed: action == VpnAction.none
                      ? () => _confirmStop(context, ref)
                      : null,
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
                Row(
                  children: [
                    Expanded(
                      child: _StatTile(
                        icon: Icons.upload,
                        label: '发送',
                        value: _formatBytes(vpn.stats.txBytes),
                      ),
                    ),
                    Expanded(
                      child: _StatTile(
                        icon: Icons.download,
                        label: '接收',
                        value: _formatBytes(vpn.stats.rxBytes),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: _StatTile(
                        icon: Icons.link,
                        label: '活动连接',
                        value: '${vpn.stats.activeConnections}',
                      ),
                    ),
                    Expanded(
                      child: _StatTile(
                        icon: Icons.dns,
                        label: 'DNS 查询',
                        value: '${vpn.stats.dnsQueries}',
                      ),
                    ),
                  ],
                ),
                if (vpn.stats.udpDropped > 0) ...[
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: _StatTile(
                          icon: Icons.block,
                          label: '丢弃 UDP（仅放行 DNS）',
                          value: '${vpn.stats.udpDropped}',
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
        if (vpn.isRunning && batteryExempted == false)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Card(
              color: Colors.amber.shade50,
              child: ListTile(
                leading: Icon(Icons.battery_saver, color: Colors.amber.shade800),
                title: const Text('关闭电池优化'),
                subtitle: const Text('防止息屏后代理断连；ColorOS 后台冻结另见系统设置。'),
                trailing: FilledButton(
                  onPressed: () async {
                    await requestBatteryExemption();
                    ref.invalidate(batteryExemptedProvider);
                  },
                  child: const Text('去设置'),
                ),
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

  Future<void> _start(
      BuildContext context, WidgetRef ref, ProxyConfig config) async {
    try {
      await runVpnAction(
        ref.read(vpnActionProvider.notifier),
        VpnAction.starting,
        () => ref.read(vpnControllerProvider).start(config),
      );
    } on VpnEngineException catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(vpnErrorText(e.code, e.message))),
        );
      }
    }
  }

  Future<void> _confirmStop(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('停止代理转发？'),
        content: const Text('停止后手机流量将直连，不再经过 Burp 抓包。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('停止'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await runVpnAction(
      ref.read(vpnActionProvider.notifier),
      VpnAction.stopping,
      () => ref.read(vpnControllerProvider).stop(),
    );
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

class _StatTile extends StatelessWidget {
  const _StatTile({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      child: Row(
        children: [
          Icon(icon, size: 20, color: Colors.grey),
          const SizedBox(width: 8),
          Expanded(
            child: Text(label, style: const TextStyle(color: Colors.grey)),
          ),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }
}
