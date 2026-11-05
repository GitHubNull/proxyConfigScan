import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/history_state.dart';

/// 历史页：扫码配置历史（M3 接入 sqflite 后展示真实数据）。
class HistoryPage extends ConsumerWidget {
  const HistoryPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entries = ref.watch(historyProvider);

    if (entries.isEmpty) {
      return const Center(
        child: Text('暂无历史记录（M3 接入 SQLite 后展示）'),
      );
    }

    return ListView.builder(
      itemCount: entries.length,
      itemBuilder: (context, index) {
        final entry = entries[index];
        return ListTile(
          leading: const Icon(Icons.dns),
          title: Text(entry.upstream),
          subtitle: entry.note.isEmpty ? null : Text(entry.note),
        );
      },
    );
  }
}
