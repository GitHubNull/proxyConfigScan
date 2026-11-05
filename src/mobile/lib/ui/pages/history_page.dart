import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/proxy_history_db.dart';
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
              onPressed: () => _reuse(context, ref, vpn),
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
      await controller.stop();
    }
    final config = ProxyConfig(
      host: record.host,
      port: record.port,
      isLanHost: ProxyUriValidator.isLanHost(record.host),
    );
    try {
      await controller.start(config);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已切换到 ${record.upstream}')),
        );
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
