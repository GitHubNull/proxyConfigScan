import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxy_config_scan/data/proxy_history_db.dart';
import 'package:proxy_config_scan/state/db_providers.dart';
import 'package:proxy_config_scan/state/history_state.dart';
import 'package:proxy_config_scan/util/proxy_uri_validator.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 首次 listAll 挂起，模拟“build 尚未完成就收到扫码”的时序。
class _GatedDb implements ProxyHistoryDb {
  _GatedDb(this.inner);

  final ProxyHistoryDb inner;
  final Completer<void> gate = Completer<void>();
  int listCalls = 0;

  @override
  Future<List<HistoryRecord>> listAll() async {
    listCalls++;
    if (listCalls == 1) await gate.future;
    return inner.listAll();
  }

  @override
  Future<void> upsert({required String host, required int port}) =>
      inner.upsert(host: host, port: port);

  @override
  Future<void> touch({required String host, required int port}) =>
      inner.touch(host: host, port: port);

  @override
  Future<void> updateNote(int id, String note) => inner.updateNote(id, note);

  @override
  Future<void> delete(int id) => inner.delete(id);

  @override
  Future<void> setLastScan({
    required String host,
    required int port,
    int? scannedAt,
  }) =>
      inner.setLastScan(host: host, port: port, scannedAt: scannedAt);

  @override
  Future<LastScan?> getLastScan() => inner.getLastScan();

  @override
  Future<void> close() => inner.close();
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('首次 build 未完成时 recordScan 不被旧列表覆盖', () async {
    final gated = _GatedDb(
      ProxyHistoryDb(
        dbName: ':memory:race${DateTime.now().microsecondsSinceEpoch}',
      ),
    );
    addTearDown(gated.close);
    final container = ProviderContainer(
      overrides: [proxyHistoryDbProvider.overrideWithValue(gated)],
    );
    addTearDown(container.dispose);

    final initial = container.read(historyProvider.future);
    final record = container
        .read(historyProvider.notifier)
        .recordScan(ProxyConfig.fromHostPort('192.168.1.10', 8080));

    gated.gate.complete();
    await initial;
    await record;

    final rows = container.read(historyProvider).value!;
    expect(rows, hasLength(1));
    expect(rows.single.upstream, '192.168.1.10:8080');
  });

  test('并发两次 recordScan 串行落库，不留半程状态', () async {
    final gated = _GatedDb(
      ProxyHistoryDb(
        dbName: ':memory:race2${DateTime.now().microsecondsSinceEpoch}',
      ),
    );
    addTearDown(gated.close);
    final container = ProviderContainer(
      overrides: [proxyHistoryDbProvider.overrideWithValue(gated)],
    );
    addTearDown(container.dispose);

    final initial = container.read(historyProvider.future);
    final first = container
        .read(historyProvider.notifier)
        .recordScan(ProxyConfig.fromHostPort('192.168.1.10', 8080));
    final second = container
        .read(historyProvider.notifier)
        .recordScan(ProxyConfig.fromHostPort('10.0.0.2', 8081));

    gated.gate.complete();
    await initial;
    await Future.wait([first, second]);

    final rows = container.read(historyProvider).value!;
    expect(rows, hasLength(2));
    expect(rows.map((r) => r.upstream).toSet(),
        {'192.168.1.10:8080', '10.0.0.2:8081'});
  });
}
