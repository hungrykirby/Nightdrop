import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nightdrop/src/scanner.dart';
import 'package:path/path.dart' as p;

import 'helpers.dart';

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('nightdrop_scan'));
  tearDown(() => tmp.deleteSync(recursive: true));

  group('isEligibleName', () {
    test('対象の拡張子は大文字・小文字を区別しない', () {
      for (final name in ['a.jpg', 'a.JPEG', 'a.png', 'a.WebP', 'a.gif']) {
        expect(isEligibleName(name), isTrue, reason: name);
      }
    });

    test('対象外の拡張子・ダウンロード途中・隠しファイルは除外する', () {
      for (final name in ['a.bmp', 'a.txt', 'a.jpg.crdownload', 'a.jpg.tmp', '.pending-1-a.jpg', '.a.jpg', 'jpg']) {
        expect(isEligibleName(name), isFalse, reason: name);
      }
    });
  });

  group('scanCandidates', () {
    final old = testNow.subtract(const Duration(hours: 1));

    Future<List<String>> names(ScanCriteria c, {Set<String> sent = const {}}) async {
      final result = await scanCandidates(tmp, c, sentKeys: sent, now: testNow);
      return result.map((e) => e.name).toList();
    }

    test('直近60秒以内に更新されたファイルは送らない', () async {
      writeImage(tmp, 'old.jpg', testNow.subtract(const Duration(seconds: 61)));
      writeImage(tmp, 'fresh.jpg', testNow.subtract(const Duration(seconds: 30)));
      expect(await names(const ScanCriteria()), ['old.jpg']);
    });

    test('開始日時より前・終了日時より後は除外し、更新日時の古い順に返す', () async {
      writeImage(tmp, 'before.jpg', DateTime(2026, 10, 1));
      writeImage(tmp, 'b.jpg', DateTime(2026, 10, 3));
      writeImage(tmp, 'a.jpg', DateTime(2026, 10, 2));
      writeImage(tmp, 'after.jpg', DateTime(2026, 10, 5));
      final c = ScanCriteria(from: DateTime(2026, 10, 2), to: DateTime(2026, 10, 4));
      expect(await names(c), ['a.jpg', 'b.jpg']);
    });

    test('送信済みの記録とパス・サイズ・更新日時が一致するものだけ除外する', () async {
      writeImage(tmp, 'sent.jpg', old);
      writeImage(tmp, 'other.jpg', old);
      final all = await scanCandidates(tmp, const ScanCriteria(), sentKeys: {}, now: testNow);
      final sentKey = all.firstWhere((c) => c.name == 'sent.jpg').key;

      expect(await names(const ScanCriteria(), sent: {sentKey}), ['other.jpg']);
      expect(await names(const ScanCriteria(excludeSent: false), sent: {sentKey}), ['other.jpg', 'sent.jpg']);

      // 同じパスでも内容が変われば（サイズ・更新日時が変われば）送り直す
      writeImage(tmp, 'sent.jpg', old.add(const Duration(minutes: 1)), content: 'changed content');
      expect(await names(const ScanCriteria(), sent: {sentKey}), ['other.jpg', 'sent.jpg']);
    });

    test('サブフォルダは含めない', () async {
      final sub = Directory(p.join(tmp.path, 'sub'))..createSync();
      writeImage(sub, 'nested.jpg', old);
      writeImage(tmp, 'top.jpg', old);
      expect(await names(const ScanCriteria()), ['top.jpg']);
    });
  });
}
