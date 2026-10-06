import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nightdrop/src/scanner.dart';
import 'package:nightdrop/src/viewer_api.dart';

import 'helpers.dart';

void main() {
  ViewerApi api(http.Client client) =>
      ViewerApi(baseUrl: 'http://192.168.0.10:5000/', token: testToken, client: client);

  group('health', () {
    Future<HealthStatus> healthWith(int code, Map<String, String> body) {
      return api(MockClient((_) async => http.Response(jsonEncode(body), code))).health().then((r) => r.status);
    }

    test('HTTP ステータスで結果を分ける', () async {
      expect(await healthWith(200, {'status': 'ok'}), HealthStatus.ok);
      expect(await healthWith(401, {'status': 'unauthorized'}), HealthStatus.unauthorized);
      expect(await healthWith(503, {'status': 'error'}), HealthStatus.tokenNotConfigured);
      expect(await healthWith(500, {'status': 'error'}), HealthStatus.serverError);
    });

    test('通信エラーは unreachable', () async {
      final client = MockClient((_) async => throw const SocketException('refused'));
      expect((await api(client).health()).status, HealthStatus.unreachable);
    });

    test('Authorization ヘッダーを付け、末尾のスラッシュを重ねない', () async {
      late http.Request seen;
      final client = MockClient((req) async {
        seen = req;
        return http.Response('{"status":"ok"}', 200);
      });
      await api(client).health();
      expect(seen.url.toString(), 'http://192.168.0.10:5000/api/health');
      expect(seen.headers['Authorization'], 'Bearer $testToken');
    });
  });

  group('upload', () {
    late Directory tmp;
    late Candidate file;
    late String hash;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('nightdrop_api');
      final f = writeImage(tmp, '画像.jpg', DateTime(2026, 10, 3, 12));
      file = Candidate(path: f.path, size: f.lengthSync(), mtimeMs: f.lastModifiedSync().millisecondsSinceEpoch);
      hash = sha256.convert(f.readAsBytesSync()).toString();
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    test('Flask ビュワーの項目名で送る（modified_at はミリ秒）', () async {
      final viewer = FakeViewer();
      final result = await api(viewer.client).upload(file, sha256: hash, batch: '2026-10-06');
      expect(result.outcome, UploadOutcome.accepted);
      expect(result.serverStatus, 'saved');
      expect(viewer.uploads.single.fields, {
        'batch': '2026-10-06',
        'sha256': hash,
        'filename': '画像.jpg',
        'modified_at': '${DateTime(2026, 10, 3, 12).millisecondsSinceEpoch}',
      });
      expect(viewer.uploads.single.filename, '画像.jpg');
    });

    test('HTTP ステータスと status で結果を分ける', () async {
      Future<UploadOutcome> outcomeOf(int code, String status) async {
        final client = MockClient((_) async => http.Response(jsonEncode({'status': status}), code));
        return (await api(client).upload(file, sha256: hash, batch: 'b')).outcome;
      }

      expect(await outcomeOf(201, 'saved'), UploadOutcome.accepted);
      expect(await outcomeOf(200, 'duplicate'), UploadOutcome.accepted);
      expect(await outcomeOf(200, 'deleted'), UploadOutcome.accepted);
      expect(await outcomeOf(400, 'invalid'), UploadOutcome.rejected);
      expect(await outcomeOf(413, 'too_large'), UploadOutcome.rejected);
      expect(await outcomeOf(422, 'corrupted'), UploadOutcome.rejected);
      expect(await outcomeOf(401, 'unauthorized'), UploadOutcome.unauthorized);
      expect(await outcomeOf(500, 'error'), UploadOutcome.serverError);
      expect(await outcomeOf(503, 'error'), UploadOutcome.serverError);
      expect(await outcomeOf(200, 'unknown'), UploadOutcome.serverError);
    });

    test('通信エラーは networkError', () async {
      final client = MockClient((_) async => throw http.ClientException('reset'));
      expect((await api(client).upload(file, sha256: hash, batch: 'b')).outcome, UploadOutcome.networkError);
    });

    test('ファイルが無ければ FileSystemException', () async {
      File(file.path).deleteSync();
      expect(
        () => api(FakeViewer().client).upload(file, sha256: hash, batch: 'b'),
        throwsA(isA<FileSystemException>()),
      );
    });
  });
}
