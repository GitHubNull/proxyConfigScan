import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/proxy_history_db.dart';
import '../util/proxy_uri_validator.dart';
import 'db_providers.dart';

/// 最近一次扫码结果，持久化到 last_scan 单行表（冷启动仍可回填启动）。
class LastScanNotifier extends AsyncNotifier<LastScan?> {
  @override
  Future<LastScan?> build() =>
      ref.watch(proxyHistoryDbProvider).getLastScan();

  Future<void> record(ProxyConfig config) async {
    // 等首次 build 落定，避免旧值覆盖新写入
    await future;
    final db = ref.read(proxyHistoryDbProvider);
    await db.setLastScan(host: config.host, port: config.port);
    state = AsyncData(await db.getLastScan());
  }
}

final lastScanProvider =
    AsyncNotifierProvider<LastScanNotifier, LastScan?>(LastScanNotifier.new);
