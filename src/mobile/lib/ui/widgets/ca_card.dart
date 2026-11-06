import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../ca/ca_state.dart';
import '../../state/last_scan_state.dart';
import '../../state/vpn_state.dart';
import '../../system/system_channel.dart';
import '../../util/proxy_uri_validator.dart';

/// 状态页「HTTPS 抓包证书」卡片：自动获取 Burp CA 并引导安装。
class CaCard extends ConsumerWidget {
  const CaCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ca = ref.watch(caProvider);
    final vpn = ref.watch(vpnSnapshotProvider).valueOrNull ??
        ref.watch(vpnControllerProvider).current;
    final lastScan = ref.watch(lastScanProvider).valueOrNull;
    final target = caTargetFrom(vpn, lastScan);
    final installed = ca.status?.installed == true;
    final busy = ca.stage == CaStage.fetching || ca.stage == CaStage.installing;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  installed ? Icons.verified_user : Icons.security,
                  color: installed ? Colors.green : Colors.orange,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'HTTPS 抓包证书',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                _StatusChip(
                  installed: installed,
                  undetectable: ca.status != null && ca.status!.installed == null,
                ),
              ],
            ),
            const SizedBox(height: 8),
            ..._body(context, ref, ca, target, busy),
          ],
        ),
      ),
    );
  }

  List<Widget> _body(
    BuildContext context,
    WidgetRef ref,
    CaUiState ca,
    ProxyConfig? target,
    bool busy,
  ) {
    final status = ca.status;
    final notifier = ref.read(caProvider.notifier);

    if (ca.stage == CaStage.checking) {
      return const [
        LinearProgressIndicator(),
        SizedBox(height: 8),
        Text('正在检测证书…'),
      ];
    }
    if (busy) {
      return [
        const LinearProgressIndicator(),
        const SizedBox(height: 8),
        Text(
          ca.stage == CaStage.fetching
              ? '正在从 ${target?.upstream ?? '代理'} 获取证书…'
              : '正在准备安装…',
        ),
      ];
    }
    if (status?.installed == true) {
      return [
        Text('已安装：${status?.subject ?? 'Burp CA'}'),
        if (status?.fingerprintSha256 != null)
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            childrenPadding: EdgeInsets.zero,
            title: const Text(
              '证书指纹（SHA-256）',
              style: TextStyle(fontSize: 13),
            ),
            children: [
              SelectableText(
                status!.fingerprintSha256!,
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ],
          ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: notifier.refresh,
            child: const Text('重新检测'),
          ),
        ),
      ];
    }

    switch (ca.stage) {
      case CaStage.saved:
        return [
          Text('已保存到 下载/${ca.fileName ?? 'BurpSuite-CA.cer'}'),
          const SizedBox(height: 4),
          const Text(
            '下一步：设置 → 安全 → 加密与凭据 → 安装证书 → CA 证书，选择该文件并确认。',
            style: TextStyle(fontSize: 13, color: Colors.grey),
          ),
          Wrap(
            spacing: 8,
            children: [
              TextButton(
                onPressed: () => SystemChannel.openSecuritySettings(),
                child: const Text('打开安全设置'),
              ),
              TextButton(
                onPressed: notifier.refresh,
                child: const Text('重新检测'),
              ),
            ],
          ),
        ];
      case CaStage.launched:
        return [
          const Text('系统安装器已打开，请在弹窗中确认安装。'),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: notifier.refresh,
              child: const Text('重新检测'),
            ),
          ),
        ];
      case CaStage.shared:
        return const [
          Text('证书已保存到临时文件，请在分享面板选择「存储到“文件”」。'),
          SizedBox(height: 4),
          Text(
            '然后到 设置 → 通用 → VPN 与设备管理 安装，'
            '再到 设置 → 通用 → 关于本机 → 证书信任设置 完全信任。',
            style: TextStyle(fontSize: 13, color: Colors.grey),
          ),
        ];
      case CaStage.error:
        return [
          Text(
            ca.error ?? '操作失败',
            style: const TextStyle(color: Colors.red),
          ),
          Wrap(
            spacing: 8,
            children: [
              if (target != null)
                FilledButton(
                  onPressed: notifier.install,
                  child: const Text('重试'),
                ),
              TextButton(
                onPressed: notifier.refresh,
                child: const Text('重新检测'),
              ),
            ],
          ),
        ];
      default:
        return [
          Text(
            status == null
                ? '正在等待证书状态…'
                : status.installed == null
                    ? '当前平台无法自动检测证书是否已安装；如未安装，HTTPS 抓包会失败。'
                    : '未安装：HTTPS 站点会提示证书错误，Burp 看不到明文。',
          ),
          if (target == null)
            const Padding(
              padding: EdgeInsets.only(top: 4),
              child: Text(
                '请先扫码或启动代理，再安装证书。',
                style: TextStyle(fontSize: 13, color: Colors.orange),
              ),
            ),
          Wrap(
            spacing: 8,
            children: [
              FilledButton.icon(
                onPressed: target == null
                    ? null
                    : () => _confirmAndInstall(context, ref, target),
                icon: const Icon(Icons.download),
                label: const Text('安装 Burp CA'),
              ),
              if (status != null)
                TextButton(
                  onPressed: notifier.refresh,
                  child: const Text('重新检测'),
                ),
            ],
          ),
        ];
    }
  }

  Future<void> _confirmAndInstall(
    BuildContext context,
    WidgetRef ref,
    ProxyConfig target,
  ) async {
    final proceed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('安装 Burp CA'),
        content: Text(
          '将从 ${target.upstream} 获取 CA 证书。\n\n'
          '${Platform.isAndroid ? 'Android 11 及以上会先保存到「下载」目录，再跳转系统安全设置，由你手动确认安装。' : 'iOS 会将证书保存到文件，请在分享面板选择「存储到“文件”」，再按引导安装并完全信任。'}\n\n'
          '只应从你信任的 Burp 代理获取证书。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('继续'),
          ),
        ],
      ),
    );
    if (proceed == true) {
      await ref.read(caProvider.notifier).install();
    }
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.installed, required this.undetectable});

  final bool installed;
  final bool undetectable;

  @override
  Widget build(BuildContext context) {
    final (label, color) = installed
        ? ('已安装', Colors.green)
        : undetectable
            ? ('无法检测', Colors.grey)
            : ('未安装', Colors.orange);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(label, style: TextStyle(color: color, fontSize: 12)),
    );
  }
}
