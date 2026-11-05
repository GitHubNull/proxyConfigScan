import 'package:sqflite/sqflite.dart';

/// 历史记录模型（proxy_history 表行）。
class HistoryRecord {
  const HistoryRecord({
    required this.id,
    required this.host,
    required this.port,
    required this.note,
    required this.createdAt,
    required this.lastUsedAt,
  });

  final int id;
  final String host;
  final int port;
  final String note;
  final int createdAt;
  final int lastUsedAt;

  String get upstream => '$host:$port';

  factory HistoryRecord.fromMap(Map<String, Object?> map) => HistoryRecord(
        id: map['id'] as int,
        host: map['host'] as String,
        port: map['port'] as int,
        note: map['note'] as String? ?? '',
        createdAt: map['created_at'] as int,
        lastUsedAt: map['last_used_at'] as int,
      );
}

/// proxy_history 表 DAO。
///
/// 表结构见 doc/architecture.md：同 host:port 复用一行（UNIQUE 约束 + upsert），
/// 排序与去重口径全部收敛在本类，UI 层只消费 [listAll] 的结果。
class ProxyHistoryDb {
  ProxyHistoryDb._();

  /// 测试可传 `dbName: ':memory:'` 获得独立内存库
  factory ProxyHistoryDb({String dbName = 'proxy_history.db'}) =>
      ProxyHistoryDb._().._dbName = dbName;

  static final ProxyHistoryDb instance = ProxyHistoryDb._();

  static const int _version = 1;

  String _dbName = 'proxy_history.db';

  Database? _db;

  Future<Database> get _database async => _db ??= await openDatabase(
        _dbName,
        version: _version,
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
      );

  /// 扫码解析成功时落库：已存在则只刷新 [HistoryRecord.lastUsedAt]，note 保留。
  Future<void> upsert({required String host, required int port}) async {
    final db = await _database;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.rawInsert(
      'INSERT INTO proxy_history (host, port, note, created_at, last_used_at) '
      'VALUES (?, ?, \'\', ?, ?) '
      'ON CONFLICT(host, port) DO UPDATE SET last_used_at = excluded.last_used_at',
      [host, port, now, now],
    );
  }

  /// 从历史记录一键复用启动时刷新使用时间。
  Future<void> touch({required String host, required int port}) async {
    final db = await _database;
    await db.update(
      'proxy_history',
      {'last_used_at': DateTime.now().millisecondsSinceEpoch},
      where: 'host = ? AND port = ?',
      whereArgs: [host, port],
    );
  }

  Future<void> updateNote(int id, String note) async {
    final db = await _database;
    await db.update(
      'proxy_history',
      {'note': note},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> delete(int id) async {
    final db = await _database;
    await db.delete('proxy_history', where: 'id = ?', whereArgs: [id]);
  }

  /// 按最近使用倒序返回全部记录。
  Future<List<HistoryRecord>> listAll() async {
    final db = await _database;
    final rows = await db.query(
      'proxy_history',
      orderBy: 'last_used_at DESC',
    );
    return rows.map(HistoryRecord.fromMap).toList();
  }
}
