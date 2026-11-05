import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 历史记录状态（M3 接入 sqflite 后充实；本期仅骨架）。
class HistoryEntry {
  const HistoryEntry({
    required this.host,
    required this.port,
    this.note = '',
  });

  final String host;
  final int port;
  final String note;

  String get upstream => '$host:$port';
}

class HistoryNotifier extends Notifier<List<HistoryEntry>> {
  @override
  List<HistoryEntry> build() => const [];

  // M3：从 sqflite 加载；增删改后落库。
}

final historyProvider =
    NotifierProvider<HistoryNotifier, List<HistoryEntry>>(HistoryNotifier.new);
