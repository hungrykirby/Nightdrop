import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nightdrop/src/database.dart';
import 'package:nightdrop/src/settings.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const testToken = 'test-token';

/// テストの基準となる現在日時
final testNow = DateTime(2026, 10, 6, 22);

Future<AppDatabase> openTestDb(Directory tmp) {
  sqfliteFfiInit();
  return AppDatabase.open(factory: databaseFactoryFfi, path: p.join(tmp.path, 'test.db'));
}

Settings testSettings(Directory source, {String serverUrl = 'http://192.168.0.10:5000', DateTime? baseline}) {
  return Settings(
    serverUrl: serverUrl,
    token: testToken,
    interval: RunInterval.daily,
    wifiOnly: true,
    chargingOnly: true,
    baseline: baseline ?? testNow.subtract(const Duration(days: 1)),
    sourceDir: source.path,
  );
}

/// [name] のファイルを作り、更新日時を [modified] にする
File writeImage(Directory dir, String name, DateTime modified, {String content = ''}) {
  final f = File(p.join(dir.path, name))..writeAsBytesSync(utf8.encode(content.isEmpty ? name : content));
  f.setLastModifiedSync(modified);
  return f;
}

class ReceivedUpload {
  const ReceivedUpload(this.fields, this.filename);

  final Map<String, String> fields;
  final String? filename;
}

/// Flask ビュワーの受信APIを真似る。SHA-256 で重複を判定する。
class FakeViewer {
  final uploads = <ReceivedUpload>[];
  final _stored = <String>{};

  /// この回数だけ受け付けた後は通信エラーにする
  int? networkErrorAfter;

  /// ファイル名がこれに一致したら 400 invalid を返す
  bool Function(String filename) rejectIf = (_) => false;

  int healthStatusCode = 200;
  int? uploadStatusCode;

  /// 1回の受信ごとに呼ぶ（時間経過のテスト用）
  void Function()? onUpload;

  http.Client get client => MockClient.streaming((request, body) async {
    await body.drain<void>();
    if (request.url.path == '/api/health') {
      final status = healthStatusCode == 200 ? 'ok' : 'error';
      return _json(healthStatusCode, {'status': status});
    }
    final multipart = request as http.MultipartRequest;
    if (networkErrorAfter != null && uploads.length >= networkErrorAfter!) {
      throw http.ClientException('Connection refused');
    }
    onUpload?.call();
    final upload = ReceivedUpload(Map.of(multipart.fields), multipart.files.single.filename);
    uploads.add(upload);
    if (uploadStatusCode == 401) return _json(401, {'status': 'unauthorized'});
    if (uploadStatusCode != null) return _json(uploadStatusCode!, {'status': 'error', 'message': 'boom'});
    if (rejectIf(upload.fields['filename']!)) return _json(400, {'status': 'invalid', 'message': '不正'});
    final sha = upload.fields['sha256']!;
    if (!_stored.add(sha)) return _json(200, {'status': 'duplicate'});
    return _json(201, {'status': 'saved'});
  });

  static http.StreamedResponse _json(int code, Map<String, Object?> body) {
    return http.StreamedResponse(
      Stream.value(utf8.encode(jsonEncode(body))),
      code,
      headers: {'content-type': 'application/json'},
    );
  }
}
