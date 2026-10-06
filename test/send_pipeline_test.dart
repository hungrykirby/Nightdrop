import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nightdrop/src/config.dart';
import 'package:nightdrop/src/database.dart';
import 'package:nightdrop/src/send_pipeline.dart';
import 'package:nightdrop/src/settings.dart';
import 'package:nightdrop/src/viewer_api.dart';

import 'helpers.dart';

void main() {
  late Directory tmp;
  late Directory source;
  late AppDatabase db;
  late FakeViewer viewer;
  late DateTime now;

  final beforeBaseline = testNow.subtract(const Duration(days: 2));
  final afterBaseline = testNow.subtract(const Duration(hours: 1));

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('nightdrop_pipeline');
    source = Directory('${tmp.path}/Download')..createSync();
    db = await openTestDb(tmp);
    viewer = FakeViewer();
    now = testNow;
  });

  tearDown(() async {
    await db.close();
    tmp.deleteSync(recursive: true);
  });

  SendPipeline pipeline({Settings? settings}) => SendPipeline(
    db: db,
    settings: settings ?? testSettings(source),
    apiFactory: (s) => ViewerApi(baseUrl: s.serverUrl, token: s.token, client: viewer.client),
    clock: () => now,
  );

  List<String> uploadedNames() => viewer.uploads.map((u) => u.fields['filename']!).toList();

  test('基準日時以降の画像だけを送り、二度目は送らない', () async {
    writeImage(source, 'old.jpg', beforeBaseline);
    writeImage(source, 'new1.jpg', afterBaseline);
    writeImage(source, 'new2.png', afterBaseline.add(const Duration(minutes: 1)));

    final first = await pipeline().run(trigger: RunTrigger.manual);
    expect(first.status, RunStatus.done);
    expect(first.sent, 2);
    expect(first.batch, '2026-10-06');
    expect(uploadedNames(), ['new1.jpg', 'new2.png']);

    final second = await pipeline().run(trigger: RunTrigger.manual);
    expect(second.status, RunStatus.done);
    expect(second.total, 0);
    expect(viewer.uploads, hasLength(2));
  });

  test('同じ日の2回目のバッチは _2 を付ける。1枚も送らなかった実行の名前は使い回す', () async {
    final empty = await pipeline().run(trigger: RunTrigger.manual);
    expect(empty.batch, '2026-10-06');

    writeImage(source, 'a.jpg', afterBaseline);
    expect((await pipeline().run(trigger: RunTrigger.manual)).batch, '2026-10-06');

    writeImage(source, 'b.jpg', afterBaseline.add(const Duration(minutes: 1)));
    expect((await pipeline().run(trigger: RunTrigger.scheduled)).batch, '2026-10-06_2');
  });

  test('通信エラーで中断し、次回は同じ batch 名で残りだけを送る', () async {
    for (var i = 0; i < 3; i++) {
      writeImage(source, 'img$i.jpg', afterBaseline.add(Duration(minutes: i)));
    }
    viewer.networkErrorAfter = 1;
    final first = await pipeline().run(trigger: RunTrigger.scheduled);
    expect(first.status, RunStatus.interrupted);
    expect(first.sent, 1);
    expect(first.message, contains('接続できませんでした'));

    // 翌日に再開しても、途中で止まった batch 名を使う
    now = testNow.add(const Duration(days: 1));
    viewer.networkErrorAfter = null;
    final second = await pipeline().run(trigger: RunTrigger.scheduled);
    expect(second.status, RunStatus.done);
    expect(second.batch, first.batch);
    expect(second.sent, 2);
    expect(uploadedNames(), ['img0.jpg', 'img1.jpg', 'img2.jpg']);
  });

  test('4xx のファイルは失敗として記録して次へ進み、次回また送る', () async {
    writeImage(source, 'bad.jpg', afterBaseline);
    writeImage(source, 'good.jpg', afterBaseline.add(const Duration(minutes: 1)));
    viewer.rejectIf = (name) => name == 'bad.jpg';

    final first = await pipeline().run(trigger: RunTrigger.manual);
    expect(first.status, RunStatus.done);
    expect((first.sent, first.failed), (1, 1));
    final failures = await db.failuresOf(first.runId!);
    expect(failures.single.path, endsWith('bad.jpg'));
    expect(failures.single.error, startsWith('invalid'));

    viewer.rejectIf = (_) => false;
    final second = await pipeline().run(trigger: RunTrigger.manual);
    expect((second.sent, second.failed), (1, 0));
    expect(uploadedNames(), ['bad.jpg', 'good.jpg', 'bad.jpg']);
  });

  test('401 と 5xx はバッチを中断する', () async {
    writeImage(source, 'a.jpg', afterBaseline);
    writeImage(source, 'b.jpg', afterBaseline.add(const Duration(minutes: 1)));

    viewer.uploadStatusCode = 401;
    final unauthorized = await pipeline().run(trigger: RunTrigger.manual);
    expect(unauthorized.status, RunStatus.interrupted);
    expect(unauthorized.message, contains('トークン'));
    expect(viewer.uploads, hasLength(1));

    viewer.uploadStatusCode = 500;
    final serverError = await pipeline().run(trigger: RunTrigger.manual);
    expect(serverError.status, RunStatus.interrupted);
    expect(viewer.uploads, hasLength(2));
    expect(await db.sentKeys(), isEmpty);
  });

  test('接続確認に失敗したら1枚も送らずに中断する', () async {
    writeImage(source, 'a.jpg', afterBaseline);
    viewer.healthStatusCode = 401;
    final summary = await pipeline().run(trigger: RunTrigger.manual);
    expect(summary.status, RunStatus.interrupted);
    expect(summary.message, HealthStatus.unauthorized.label);
    expect(viewer.uploads, isEmpty);
  });

  test('ローカルネットワーク外の http URL には送らない', () async {
    writeImage(source, 'a.jpg', afterBaseline);
    final summary = await pipeline(settings: testSettings(source, serverUrl: 'http://8.8.8.8:5000'))
        .run(trigger: RunTrigger.manual);
    expect(summary.status, RunStatus.failed);
    expect(viewer.uploads, isEmpty);
  });

  test('送信前に消えたファイルは失敗にせず飛ばす', () async {
    writeImage(source, 'stay.jpg', afterBaseline);
    final gone = writeImage(source, 'gone.jpg', afterBaseline.add(const Duration(minutes: 1)));
    // 1枚目を受信した時点（走査の後、2枚目の送信前）で2枚目を消す
    viewer.onUpload = () {
      if (gone.existsSync()) gone.deleteSync();
    };
    final summary = await pipeline().run(trigger: RunTrigger.manual);
    expect(summary.status, RunStatus.done);
    expect((summary.total, summary.sent, summary.failed), (2, 1, 0));
    expect(uploadedNames(), ['stay.jpg']);
  });

  test('実行時間の上限を過ぎたら区切り、次回続きを送る', () async {
    for (var i = 0; i < 3; i++) {
      writeImage(source, 'img$i.jpg', afterBaseline.add(Duration(minutes: i)));
    }
    viewer.onUpload = () => now = now.add(const Duration(minutes: 5));
    final first = await pipeline().run(trigger: RunTrigger.scheduled, timeBudget: scheduledTimeBudget);
    expect(first.status, RunStatus.interrupted);
    expect(first.sent, 2);

    final second = await pipeline().run(trigger: RunTrigger.scheduled, timeBudget: scheduledTimeBudget);
    expect(second.batch, first.batch);
    expect(second.sent, 1);
  });

  test('別の実行がロックを持っていれば何もしない。古いロックは奪う', () async {
    writeImage(source, 'a.jpg', afterBaseline);
    expect(await db.tryAcquireLock('other', now, lockStaleAfter), isTrue);

    final busy = await pipeline().run(trigger: RunTrigger.manual);
    expect(busy.isBusy, isTrue);
    expect(await db.latestRun(), isNull);

    now = now.add(lockStaleAfter);
    final summary = await pipeline().run(trigger: RunTrigger.manual);
    expect(summary.status, RunStatus.done);
  });

  group('一括送信', () {
    test('基準日時を無視して期間内を送り、送信済みは除外する', () async {
      writeImage(source, 'old.jpg', beforeBaseline);
      writeImage(source, 'older.jpg', beforeBaseline.subtract(const Duration(days: 3)));
      writeImage(source, 'new.jpg', afterBaseline);
      await pipeline().run(trigger: RunTrigger.manual);
      expect(uploadedNames(), ['new.jpg']);

      final bulk = BulkRequest(from: beforeBaseline.subtract(const Duration(hours: 1)));
      final summary = await pipeline().run(trigger: RunTrigger.bulk, bulk: bulk);
      expect(summary.status, RunStatus.done);
      expect(summary.batch, '2026-10-06_2');
      expect(uploadedNames(), ['new.jpg', 'old.jpg']);

      final latest = await db.latestRun();
      expect(latest!.trigger, RunTrigger.bulk);
      expect(latest.rangeFrom, bulk.from);
    });

    test('送り直す場合は送信済みも送り、サーバーは duplicate を返す', () async {
      writeImage(source, 'a.jpg', afterBaseline);
      await pipeline().run(trigger: RunTrigger.manual);

      final summary = await pipeline().run(
        trigger: RunTrigger.bulk,
        bulk: BulkRequest(from: beforeBaseline, resend: true),
      );
      expect((summary.sent, summary.duplicate), (0, 1));
    });

    test('定期送信が途中で止まっていても、一括送信は新しい batch 名を使う', () async {
      writeImage(source, 'a.jpg', afterBaseline);
      writeImage(source, 'b.jpg', afterBaseline.add(const Duration(minutes: 1)));
      viewer.networkErrorAfter = 1;
      final regular = await pipeline().run(trigger: RunTrigger.scheduled);
      expect(regular.status, RunStatus.interrupted);

      viewer.networkErrorAfter = null;
      final bulk = await pipeline().run(trigger: RunTrigger.bulk, bulk: BulkRequest(from: beforeBaseline));
      expect(bulk.batch, isNot(regular.batch));

      // 一括送信の後でも、定期送信は止まった batch 名で再開する
      writeImage(source, 'c.jpg', afterBaseline.add(const Duration(minutes: 2)));
      final resumed = await pipeline().run(trigger: RunTrigger.scheduled);
      expect(resumed.batch, regular.batch);
    });

    test('中止すると記録を残して終わる', () async {
      for (var i = 0; i < 3; i++) {
        writeImage(source, 'img$i.jpg', afterBaseline.add(Duration(minutes: i)));
      }
      var cancel = false;
      final summary = await pipeline().run(
        trigger: RunTrigger.bulk,
        bulk: BulkRequest(from: beforeBaseline),
        isCancelled: () => cancel,
        onProgress: (p) => cancel = p.done == 1,
      );
      expect(summary.status, RunStatus.interrupted);
      expect(summary.sent, 1);
      expect((await db.latestRun())!.sent, 1);
    });
  });
}
