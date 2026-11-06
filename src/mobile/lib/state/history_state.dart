import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/proxy_history_db.dart';
import '../util/proxy_uri_validator.dart';
import 'db_providers.dart';

/// 历史记录状态：加载/增删改后从 [ProxyHistoryDb] 重取，保证 UI 与库一致。
class HistoryNotifier extends AsyncNotifier<List<HistoryRecord>> {
  Future<void> _queue = Future<void>.value();

  ProxyHistoryDb get _db => ref.read(proxyHistoryDbProvider);

  @override
  Future<List<HistoryRecord>> build() =>
      ref.watch(proxyHistoryDbProvider).listAll();

  /// 串行 mutation：先等首次 build 落定，再写库并整体重取，
  /// 避免“旧列表晚到覆盖新数据”的竞态。
  Future<void> _mutate(Future<void> Function(ProxyHistoryDb db) action) {
    final task = _queue.then((_) async {
      await future;
      final db = _db;
      await action(db);
      state = AsyncData(await db.listAll());
    });
    _queue = task.catchError((Object _) {});
    return task;
  }

  Future<void> recordScan(ProxyConfig config) =>
      _mutate((db) => db.upsert(host: config.host, port: config.port));

  Future<void> touch(ProxyConfig config) =>
      _mutate((db) => db.touch(host: config.host, port: config.port));

  Future<void> updateNote(HistoryRecord record, String note) =>
      _mutate((db) => db.updateNote(record.id, note));

  Future<void> delete(HistoryRecord record) =>
      _mutate((db) => db.delete(record.id));
}

final historyProvider =
    AsyncNotifierProvider<HistoryNotifier, List<HistoryRecord>>(
  HistoryNotifier.new,
);
