import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/proxy_history_db.dart';
import '../util/proxy_uri_validator.dart';

/// 历史记录状态：加载/增删改后从 [ProxyHistoryDb] 重取，保证 UI 与库一致。
class HistoryNotifier extends AsyncNotifier<List<HistoryRecord>> {
  @override
  Future<List<HistoryRecord>> build() =>
      ProxyHistoryDb.instance.listAll();

  Future<void> recordScan(ProxyConfig config) async {
    await ProxyHistoryDb.instance.upsert(host: config.host, port: config.port);
    state = AsyncData(await ProxyHistoryDb.instance.listAll());
  }

  Future<void> touch(ProxyConfig config) async {
    await ProxyHistoryDb.instance.touch(host: config.host, port: config.port);
    state = AsyncData(await ProxyHistoryDb.instance.listAll());
  }

  Future<void> updateNote(HistoryRecord record, String note) async {
    await ProxyHistoryDb.instance.updateNote(record.id, note);
    state = AsyncData(await ProxyHistoryDb.instance.listAll());
  }

  Future<void> delete(HistoryRecord record) async {
    await ProxyHistoryDb.instance.delete(record.id);
    state = AsyncData(await ProxyHistoryDb.instance.listAll());
  }
}

final historyProvider =
    AsyncNotifierProvider<HistoryNotifier, List<HistoryRecord>>(
  HistoryNotifier.new,
);
