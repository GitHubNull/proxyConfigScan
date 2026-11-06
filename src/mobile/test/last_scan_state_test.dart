import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxy_config_scan/data/proxy_history_db.dart';
import 'package:proxy_config_scan/state/db_providers.dart';
import 'package:proxy_config_scan/state/last_scan_state.dart';
import 'package:proxy_config_scan/util/proxy_uri_validator.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('冷启动读取 last_scan，record 写入并刷新 state', () async {
    final db = ProxyHistoryDb(
      dbName: ':memory:lastscan${DateTime.now().microsecondsSinceEpoch}',
    );
    addTearDown(db.close);
    await db.setLastScan(host: '192.168.1.10', port: 8080, scannedAt: 1000);

    final container = ProviderContainer(
      overrides: [proxyHistoryDbProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);

    final initial = await container.read(lastScanProvider.future);
    expect(initial?.upstream, '192.168.1.10:8080');
    expect(initial?.toConfig().isLanHost, isTrue);

    await container
        .read(lastScanProvider.notifier)
        .record(ProxyConfig.fromHostPort('10.0.0.2', 8081));

    final value = container.read(lastScanProvider).value;
    expect(value?.upstream, '10.0.0.2:8081');
    expect(value?.scannedAt, greaterThan(1000));
    expect((await db.getLastScan())?.host, '10.0.0.2');
  });
}
