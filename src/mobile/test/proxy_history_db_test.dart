import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxy_config_scan/data/proxy_history_db.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  // sqflite_common_ffi 把非精确 ':memory:' 的路径当文件库，
  // 且跨测试进程残留；用本次运行唯一前缀保证隔离
  var seq = 0;
  final runId = DateTime.now().microsecondsSinceEpoch;
  final opened = <ProxyHistoryDb>[];
  final names = <String>[];

  ProxyHistoryDb freshDb() {
    final name = ':memory:history${runId}_${seq++}';
    final db = ProxyHistoryDb(dbName: name);
    opened.add(db);
    names.add(name);
    return db;
  }

  tearDownAll(() async {
    for (final db in opened) {
      await db.close();
    }
    for (final name in names) {
      await databaseFactory.deleteDatabase(name);
    }
  });

  test('同 host:port upsert 两次仅一条，last_used_at 更新', () async {
    final db = freshDb();
    await db.upsert(host: '192.168.1.10', port: 8080);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await db.upsert(host: '192.168.1.10', port: 8080);

    final rows = await db.listAll();
    expect(rows, hasLength(1));
    expect(rows.single.host, '192.168.1.10');
    expect(rows.single.upstream, '192.168.1.10:8080');
  });

  test('不同 port 是两条记录', () async {
    final db = freshDb();
    await db.upsert(host: '192.168.1.10', port: 8080);
    await db.upsert(host: '192.168.1.10', port: 8081);

    final rows = await db.listAll();
    expect(rows, hasLength(2));
  });

  test('upsert 已存在行保留 note', () async {
    final db = freshDb();
    await db.upsert(host: '10.0.0.2', port: 8080);
    final first = (await db.listAll()).single;
    await db.updateNote(first.id, '测试机 Burp');

    await db.upsert(host: '10.0.0.2', port: 8080);

    final rows = await db.listAll();
    expect(rows, hasLength(1));
    expect(rows.single.note, '测试机 Burp');
  });

  test('listAll 按 last_used_at 倒序', () async {
    final db = freshDb();
    await db.upsert(host: '192.168.1.10', port: 8080);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await db.upsert(host: '192.168.1.20', port: 8080);

    var rows = await db.listAll();
    expect(rows.first.upstream, '192.168.1.20:8080');

    // 复用旧条目后它应排到最前
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await db.upsert(host: '192.168.1.10', port: 8080);
    rows = await db.listAll();
    expect(rows.first.upstream, '192.168.1.10:8080');
  });

  test('touch 刷新 last_used_at 且不影响其他行', () async {
    final db = freshDb();
    await db.upsert(host: '192.168.1.10', port: 8080);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await db.upsert(host: '192.168.1.20', port: 8080);
    final before = (await db.listAll()).firstWhere(
      (r) => r.upstream == '192.168.1.20:8080',
    );

    await Future<void>.delayed(const Duration(milliseconds: 5));
    await db.touch(host: '192.168.1.20', port: 8080);

    final rows = await db.listAll();
    final after = rows.firstWhere((r) => r.upstream == '192.168.1.20:8080');
    expect(after.lastUsedAt, greaterThan(before.lastUsedAt));
    expect(rows.first.upstream, '192.168.1.20:8080');
  });

  test('updateNote / delete', () async {
    final db = freshDb();
    await db.upsert(host: '172.16.0.5', port: 9090);
    final row = (await db.listAll()).single;

    await db.updateNote(row.id, '公司 Burp');
    expect((await db.listAll()).single.note, '公司 Burp');

    await db.delete(row.id);
    expect(await db.listAll(), isEmpty);
  });

  test('last_scan 单行覆盖写，toConfig 回填局域网判定', () async {
    final db = freshDb();
    expect(await db.getLastScan(), isNull);

    await db.setLastScan(host: '192.168.1.10', port: 8080, scannedAt: 1000);
    await db.setLastScan(host: '10.0.0.2', port: 8081, scannedAt: 2000);

    final last = await db.getLastScan();
    expect(last, isNotNull);
    expect(last!.upstream, '10.0.0.2:8081');
    expect(last.scannedAt, 2000);
    expect(last.toConfig().isLanHost, isTrue);
  });

  test('v1 库升级到 v2 保留历史并新增 last_scan', () async {
    final path =
        '${Directory.systemTemp.path}/proxy_v1_${DateTime.now().microsecondsSinceEpoch}.db';
    final v1 = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, version) => db.execute('''
          CREATE TABLE proxy_history (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            host TEXT NOT NULL,
            port INTEGER NOT NULL,
            note TEXT NOT NULL DEFAULT '',
            created_at INTEGER NOT NULL,
            last_used_at INTEGER NOT NULL,
            UNIQUE(host, port)
          )
        '''),
      ),
    );
    await v1.insert('proxy_history', {
      'host': '172.16.0.5',
      'port': 9090,
      'note': '旧记录',
      'created_at': 1000,
      'last_used_at': 1000,
    });
    await v1.close();

    final db = ProxyHistoryDb(dbName: path);
    final rows = await db.listAll();
    expect(rows.single.upstream, '172.16.0.5:9090');
    expect(rows.single.note, '旧记录');
    expect(await db.getLastScan(), isNull);

    await db.setLastScan(host: '192.168.1.10', port: 8080);
    expect((await db.getLastScan())?.upstream, '192.168.1.10:8080');

    await db.close();
    await databaseFactory.deleteDatabase(path);
  });
}
