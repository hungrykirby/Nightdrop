import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

const _dbName = 'nightdrop.db';
const _dbVersion = 1;

enum RunTrigger {
  scheduled('定期'),
  manual('手動'),
  bulk('一括');

  const RunTrigger(this.label);

  final String label;
}

enum RunStatus {
  running('実行中'),
  done('完了'),
  interrupted('中断'),
  failed('失敗');

  const RunStatus(this.label);

  final String label;

  /// 次回の定期送信・手動送信で同じ batch 名のまま続きを送る状態
  bool get isResumable => this == interrupted || this == failed;
}

/// 送信済みの判定キー（仕様書 8章 sent_files の主キー）
String sentKey(String path, int size, int mtimeMs) => '$path\u0000$size\u0000$mtimeMs';

class RunRecord {
  const RunRecord({
    required this.id,
    required this.batch,
    required this.trigger,
    required this.startedAt,
    required this.status,
    this.rangeFrom,
    this.rangeTo,
    this.resend = false,
    this.finishedAt,
    this.sent = 0,
    this.duplicate = 0,
    this.failed = 0,
    this.message,
  });

  factory RunRecord.fromRow(Map<String, Object?> r) => RunRecord(
    id: r['id'] as int,
    batch: r['batch'] as String,
    trigger: RunTrigger.values.byName(r['trigger'] as String),
    rangeFrom: _parseDate(r['range_from']),
    rangeTo: _parseDate(r['range_to']),
    resend: r['resend'] == 1,
    startedAt: DateTime.parse(r['started_at'] as String),
    finishedAt: _parseDate(r['finished_at']),
    status: RunStatus.values.byName(r['status'] as String),
    sent: r['sent'] as int,
    duplicate: r['duplicate'] as int,
    failed: r['failed'] as int,
    message: r['message'] as String?,
  );

  final int id;
  final String batch;
  final RunTrigger trigger;
  final DateTime? rangeFrom;
  final DateTime? rangeTo;
  final bool resend;
  final DateTime startedAt;
  final DateTime? finishedAt;
  final RunStatus status;
  final int sent;
  final int duplicate;
  final int failed;
  final String? message;

  static DateTime? _parseDate(Object? v) => v == null ? null : DateTime.parse(v as String);
}

class FailureRecord {
  const FailureRecord(this.path, this.error);

  final String path;
  final String error;
}

class AppDatabase {
  AppDatabase._(this._db);

  final Database _db;

  /// [factory] と [path] はテスト用（sqflite_common_ffi のメモリDBなど）
  static Future<AppDatabase> open({DatabaseFactory? factory, String? path}) async {
    final f = factory ?? databaseFactory;
    final dbPath = path ?? p.join(await f.getDatabasesPath(), _dbName);
    final db = await f.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(version: _dbVersion, onCreate: _create),
    );
    return AppDatabase._(db);
  }

  static Future<void> _create(Database db, int version) async {
    final batch = db.batch()
      ..execute('''
        CREATE TABLE sent_files (
          path    TEXT NOT NULL,
          size    INTEGER NOT NULL,
          mtime   INTEGER NOT NULL,
          sha256  TEXT NOT NULL,
          batch   TEXT NOT NULL,
          result  TEXT NOT NULL,
          sent_at TEXT NOT NULL,
          PRIMARY KEY (path, size, mtime)
        )''')
      ..execute('''
        CREATE TABLE runs (
          id          INTEGER PRIMARY KEY AUTOINCREMENT,
          batch       TEXT NOT NULL,
          trigger     TEXT NOT NULL,
          range_from  TEXT,
          range_to    TEXT,
          resend      INTEGER DEFAULT 0,
          started_at  TEXT NOT NULL,
          finished_at TEXT,
          status      TEXT NOT NULL,
          sent        INTEGER DEFAULT 0,
          duplicate   INTEGER DEFAULT 0,
          failed      INTEGER DEFAULT 0,
          message     TEXT
        )''')
      ..execute('''
        CREATE TABLE failures (
          run_id INTEGER NOT NULL,
          path   TEXT NOT NULL,
          error  TEXT NOT NULL
        )''')
      // 定期・手動・一括の同時実行を防ぐロック（isolate をまたぐため DB に置く）
      ..execute('''
        CREATE TABLE run_lock (
          id           INTEGER PRIMARY KEY CHECK (id = 1),
          owner        TEXT NOT NULL,
          heartbeat_at INTEGER NOT NULL
        )''');
    await batch.commit(noResult: true);
  }

  Future<void> close() => _db.close();

  // ---------- 送信済みの記録 ----------

  Future<Set<String>> sentKeys() async {
    final rows = await _db.query('sent_files', columns: ['path', 'size', 'mtime']);
    return {
      for (final r in rows) sentKey(r['path'] as String, r['size'] as int, r['mtime'] as int),
    };
  }

  Future<void> recordSent({
    required String path,
    required int size,
    required int mtimeMs,
    required String sha256,
    required String batch,
    required String result,
    required DateTime sentAt,
  }) {
    return _db.insert('sent_files', {
      'path': path,
      'size': size,
      'mtime': mtimeMs,
      'sha256': sha256,
      'batch': batch,
      'result': result,
      'sent_at': sentAt.toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// [date]（YYYY-MM-DD）またはその連番（_2 など）で、実際に画像を送った batch 名。
  /// 1枚も送らずに終わった実行の名前は使用済みにしない。
  Future<Set<String>> batchNamesOn(String date) async {
    final rows = await _db.rawQuery(
      'SELECT DISTINCT batch FROM sent_files WHERE batch = ? OR batch LIKE ?',
      [date, '${date}_%'],
    );
    return {for (final r in rows) r['batch'] as String};
  }

  // ---------- 実行の記録 ----------

  Future<int> startRun({
    required String batch,
    required RunTrigger trigger,
    required DateTime startedAt,
    DateTime? rangeFrom,
    DateTime? rangeTo,
    bool resend = false,
  }) {
    return _db.insert('runs', {
      'batch': batch,
      'trigger': trigger.name,
      'range_from': rangeFrom?.toIso8601String(),
      'range_to': rangeTo?.toIso8601String(),
      'resend': resend ? 1 : 0,
      'started_at': startedAt.toIso8601String(),
      'status': RunStatus.running.name,
    });
  }

  Future<void> updateRunCounts(int id, {required int sent, required int duplicate, required int failed}) {
    return _db.update(
      'runs',
      {'sent': sent, 'duplicate': duplicate, 'failed': failed},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> finishRun(int id, {required RunStatus status, required DateTime finishedAt, String? message}) {
    return _db.update(
      'runs',
      {'status': status.name, 'finished_at': finishedAt.toIso8601String(), 'message': message},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> addFailure(int runId, String path, String error) {
    return _db.insert('failures', {'run_id': runId, 'path': path, 'error': error});
  }

  Future<RunRecord?> latestRun({Set<RunTrigger>? triggers}) async {
    final rows = await _db.query(
      'runs',
      where: triggers == null ? null : 'trigger IN (${List.filled(triggers.length, '?').join(', ')})',
      whereArgs: triggers?.map((t) => t.name).toList(),
      orderBy: 'id DESC',
      limit: 1,
    );
    return rows.isEmpty ? null : RunRecord.fromRow(rows.first);
  }

  Future<List<RunRecord>> recentRuns({int limit = 50}) async {
    final rows = await _db.query('runs', orderBy: 'id DESC', limit: limit);
    return rows.map(RunRecord.fromRow).toList();
  }

  Future<List<FailureRecord>> failuresOf(int runId) async {
    final rows = await _db.query('failures', where: 'run_id = ?', whereArgs: [runId]);
    return [for (final r in rows) FailureRecord(r['path'] as String, r['error'] as String)];
  }

  // ---------- ロック ----------

  /// ロックを取れたら true。前の持ち主の更新が [staleAfter] より古ければ奪う。
  Future<bool> tryAcquireLock(String owner, DateTime now, Duration staleAfter) {
    return _db.transaction((txn) async {
      final rows = await txn.query('run_lock', where: 'id = 1');
      if (rows.isNotEmpty) {
        final heartbeat = rows.first['heartbeat_at'] as int;
        if (now.millisecondsSinceEpoch - heartbeat < staleAfter.inMilliseconds) return false;
      }
      await txn.insert('run_lock', {
        'id': 1,
        'owner': owner,
        'heartbeat_at': now.millisecondsSinceEpoch,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      return true;
    }, exclusive: true);
  }

  Future<void> heartbeatLock(String owner, DateTime now) {
    return _db.update(
      'run_lock',
      {'heartbeat_at': now.millisecondsSinceEpoch},
      where: 'id = 1 AND owner = ?',
      whereArgs: [owner],
    );
  }

  Future<void> releaseLock(String owner) {
    return _db.delete('run_lock', where: 'id = 1 AND owner = ?', whereArgs: [owner]);
  }
}
