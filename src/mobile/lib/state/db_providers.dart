import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/proxy_history_db.dart';

/// 数据库入口；测试用内存库 override。
final proxyHistoryDbProvider = Provider<ProxyHistoryDb>(
  (ref) => ProxyHistoryDb.instance,
);
