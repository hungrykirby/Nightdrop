// 実際の Flask ビュワーとの結合テスト。tool/flask_integration_test.sh から実行する。
// 環境変数が無ければスキップする。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nightdrop/src/database.dart';
import 'package:nightdrop/src/send_pipeline.dart';
import 'package:nightdrop/src/viewer_api.dart';
import 'package:path/path.dart' as p;

import '../helpers.dart';

// 1x1 の PNG
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
);

void main() {
  final env = Platform.environment;
  final url = env['NIGHTDROP_FLASK_URL'];
  final token = env['NIGHTDROP_FLASK_TOKEN'];
  final library = env['NIGHTDROP_FLASK_LIBRARY'];
  final skip = url == null || token == null || library == null
      ? 'tool/flask_integration_test.sh から実行してください'
      : null;

  late Directory tmp;
  late Directory source;
  late AppDatabase db;
  var counter = 0;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('nightdrop_flask');
    source = Directory(p.join(tmp.path, 'Download'))..createSync();
    db = await openTestDb(tmp);
  });

  tearDown(() async {
    await db.close();
    tmp.deleteSync(recursive: true);
  });

  /// サーバー側で過去のテストの画像と重複しないよう、末尾に連番を付けた PNG を作る
  File png(String name, DateTime modified) {
    final f = File(p.join(source.path, name))..writeAsBytesSync([..._png, ...utf8.encode('${counter++}-$name')]);
    f.setLastModifiedSync(modified);
    return f;
  }

  SendPipeline pipeline({String? overrideToken}) {
    final s = testSettings(source, serverUrl: url!, baseline: DateTime.now().subtract(const Duration(days: 1)));
    return SendPipeline(
      db: db,
      settings: s,
      apiFactory: (s) => ViewerApi(baseUrl: s.serverUrl, token: overrideToken ?? token!),
    );
  }

  final modified = DateTime.now().subtract(const Duration(hours: 1));

  test('接続確認：トークンが正しければ ok、違えば unauthorized', () async {
    expect((await ViewerApi(baseUrl: url!, token: token!).health()).status, HealthStatus.ok);
    expect((await ViewerApi(baseUrl: url, token: 'wrong').health()).status, HealthStatus.unauthorized);
  }, skip: skip);

  test('送った画像が batch 名のフォルダに元の更新日時で保存され、送り直すと duplicate になる', () async {
    png('夜景.png', modified);
    png('b.png', modified.add(const Duration(minutes: 1)));

    final first = await pipeline().run(trigger: RunTrigger.manual);
    expect(first.status, RunStatus.done, reason: first.message);
    expect(first.sent, 2);

    final saved = File(p.join(library!, first.batch, '夜景.png'));
    expect(saved.existsSync(), isTrue);
    expect(saved.lastModifiedSync().millisecondsSinceEpoch ~/ 1000, modified.millisecondsSinceEpoch ~/ 1000);

    final resend = await pipeline().run(
      trigger: RunTrigger.bulk,
      bulk: BulkRequest(from: modified.subtract(const Duration(minutes: 1)), resend: true),
    );
    expect((resend.sent, resend.duplicate), (0, 2));
  }, skip: skip);

  test('画像でないファイルは 422 corrupted で失敗として記録し、次のファイルは送る', () async {
    File(p.join(source.path, 'broken.jpg'))
      ..writeAsStringSync('not an image ${counter++}')
      ..setLastModifiedSync(modified);
    png('ok.png', modified.add(const Duration(minutes: 1)));

    final summary = await pipeline().run(trigger: RunTrigger.manual);
    expect(summary.status, RunStatus.done, reason: summary.message);
    expect((summary.sent, summary.failed), (1, 1));
    expect((await db.failuresOf(summary.runId!)).single.error, startsWith('corrupted'));
  }, skip: skip);

  test('トークンが違えば1枚も送らずに中断する', () async {
    png('a.png', modified);
    final summary = await pipeline(overrideToken: 'wrong').run(trigger: RunTrigger.manual);
    expect(summary.status, RunStatus.interrupted);
    expect(summary.sent, 0);
  }, skip: skip);
}
