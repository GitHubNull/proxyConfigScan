import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/proxy_history_db.dart';
import '../../state/app_state.dart';
import '../../state/history_state.dart';
import '../../state/vpn_state.dart';
import '../../util/proxy_uri_validator.dart';
import '../../vpn/proxy_engine.dart' hide VpnSnapshot;

/// 历史页：扫码落库的代理配置列表，支持一键复用启动、备注编辑、删除。
class HistoryPage extends ConsumerWidget {
  const HistoryPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncEntries = ref.watch(historyProvider);

    return asyncEntries.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('历史记录加载失败：$e')),
      data: (entries) {
        if (entries.isEmpty) {
          return const Center(
            child: Text('暂无历史记录\n扫码解析成功后会自动记录到这里',
                textAlign: TextAlign.center),
          );
        }
        return ListView.separated(
          itemCount: entries.length,
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (context, index) => _HistoryTile(record: entries[index]),
        );
      },
    );
  }
}

class _HistoryTile extends ConsumerWidget {
  const _HistoryTile({required this.record});

  final HistoryRecord record;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final vpn = ref.watch(vpnSnapshotProvider).value ??
        ref.watch(vpnControllerProvider).current;
    final isCurrent = vpn.isRunning && vpn.upstream == record.upstream;
    final busy = ref.watch(vpnActionProvider) != VpnAction.none;

    return ListTile(
      leading: Icon(
        Icons.dns,
        color: isCurrent ? Colors.green : null,
      ),
      title: Text(record.upstream),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (record.note.isNotEmpty) Text(record.note),
          Text(
            '上次使用 ${_formatTime(record.lastUsedAt)}',
            style: const TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ],
      ),
      isThreeLine: record.note.isNotEmpty,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isCurrent)
            const Icon(Icons.check_circle, color: Colors.green, size: 20),
          if (!isCurrent)
            IconButton(
              tooltip: '使用该代理',
              icon: const Icon(Icons.play_arrow),
              onPressed: busy ? null : () => _reuse(context, ref, vpn),
            ),
          IconButton(
            tooltip: '编辑备注',
            icon: const Icon(Icons.edit_note),
            onPressed: () => _editNote(context, ref),
          ),
          IconButton(
            tooltip: '删除',
            icon: const Icon(Icons.delete_outline),
            onPressed: () => _confirmDelete(context, ref),
          ),
        ],
      ),
    );
  }

  Future<void> _reuse(
      BuildContext context, WidgetRef ref, VpnSnapshot vpn) async {
    // 校验先于一切确认：回环地址必败，直接拦截（顺序必须先回环后公网，
    // 因为 isLanHost 把 127/8 也算私网段）
    if (ProxyUriValidator.isLoopback(record.host)) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('地址不可用'),
          content: Text(
            '${record.host} 是回环地址（手机本机），Burp 代理并不在手机上，启动后必然连不上。\n\n'
            '请在 Burp 代理监听器绑定电脑局域网 IP（或全部接口）后重新扫码。',
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('知道了'),
            ),
          ],
        ),
      );
      return;
    }
    if (!ProxyUriValidator.isLanHost(record.host)) {
      final proceed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('目标不在局域网'),
          content: Text('$record.upstream 似乎不是局域网地址，手机可能无法连通。仍要启动吗？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('仍要启动'),
            ),
          ],
        ),
      );
      if (proceed != true || !context.mounted) return;
    }
    final action = ref.read(vpnActionProvider.notifier);
    final controller = ref.read(vpnControllerProvider);
    if (vpn.isRunning) {
      final switchIt = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('切换代理上游'),
          content: Text('当前运行的是 ${vpn.upstream}，将停止后改用 ${record.upstream}。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('切换'),
            ),
          ],
        ),
      );
      if (switchIt != true || !context.mounted) return;
      await runVpnAction(action, VpnAction.stopping, () => controller.stop());
    }
    final config = ProxyConfig(
      host: record.host,
      port: record.port,
      isLanHost: ProxyUriValidator.isLanHost(record.host),
    );
    try {
      await runVpnAction(action, VpnAction.starting, () => controller.start(config));
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已切换到 ${record.upstream}')),
        );
        ref.read(tabIndexProvider.notifier).state = 1;
      }
    } on VpnEngineException catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(vpnErrorText(e.code, e.message))),
        );
      }
    }
  }

  Future<void> _editNote(BuildContext context, WidgetRef ref) async {
    final controller = TextEditingController(text: record.note);
    final saved = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('编辑备注'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 50,
          decoration: const InputDecoration(hintText: '例如：测试机 Burp'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (saved != null) {
      await ref.read(historyProvider.notifier).updateNote(record, saved);
    }
  }

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除这条记录？'),
        content: Text(record.upstream),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await ref.read(historyProvider.notifier).delete(record);
    }
  }

  static String _formatTime(int millis) {
    final dt = DateTime.fromMillisecondsSinceEpoch(millis);
    final now = DateTime.now();
    final sameDay = dt.year == now.year && dt.month == now.month && dt.day == now.day;
    final hm =
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    if (sameDay) return '今天 $hm';
    return '${dt.month}-${dt.day.toString().padLeft(2, '0')} $hm';
  }
}
