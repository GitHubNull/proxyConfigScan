import 'package:flutter_test/flutter_test.dart';
import 'package:proxy_config_scan/data/proxy_history_db.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  // sqflite_common_ffi 按路径缓存库实例，同名 ':memory:' 会被共享；
  // 每用例唯一库名保证隔离
  var _seq = 0;
  ProxyHistoryDb freshDb() => ProxyHistoryDb(dbName: ':memory:history${_seq++}');

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
}
