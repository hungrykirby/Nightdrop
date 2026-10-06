import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'config.dart';
import 'scanner.dart';

/// Flask ビュワーの受信API（../local-image-viewer/README.md「API（Nightdrop向け）」）

enum HealthStatus {
  ok('接続できました'),
  unauthorized('トークンが違います'),
  tokenNotConfigured('サーバーでトークン（VIEWER_UPLOAD_TOKEN）が設定されていません'),
  serverError('サーバーでエラーが発生しました'),
  unreachable('接続できませんでした');

  const HealthStatus(this.label);

  final String label;
}

class HealthResult {
  const HealthResult(this.status, [this.detail]);

  final HealthStatus status;
  final String? detail;

  bool get isOk => status == HealthStatus.ok;

  String get message => detail == null ? status.label : '${status.label}（$detail）';
}

enum UploadOutcome {
  /// saved / duplicate / deleted。送信済みとして記録する
  accepted,

  /// 401 以外の 4xx。このファイルを失敗として次へ進む
  rejected,

  /// 401。バッチを中断する
  unauthorized,

  /// 5xx など。バッチを中断する
  serverError,

  /// 通信エラー・タイムアウト。バッチを中断する
  networkError;

  bool get abortsBatch => this == unauthorized || this == serverError || this == networkError;
}

class UploadResult {
  const UploadResult(this.outcome, {this.serverStatus, this.message = ''});

  final UploadOutcome outcome;

  /// レスポンスJSONの status（saved / duplicate / deleted / invalid など）
  final String? serverStatus;
  final String message;
}

const _acceptedStatuses = {'saved', 'duplicate', 'deleted'};

class ViewerApi {
  ViewerApi({required String baseUrl, required this.token, http.Client? client})
    : _base = Uri.parse(baseUrl.trim().replaceFirst(RegExp(r'/+$'), '')),
      _client = client ?? http.Client();

  final Uri _base;
  final String token;
  final http.Client _client;

  Map<String, String> get _auth => {'Authorization': 'Bearer $token'};

  Uri _endpoint(String path) => _base.replace(path: '${_base.path}$path');

  void close() => _client.close();

  Future<HealthResult> health() async {
    final http.Response res;
    try {
      res = await _client.get(_endpoint('/api/health'), headers: _auth).timeout(healthTimeout);
    } on Exception catch (e) {
      return HealthResult(HealthStatus.unreachable, _describe(e));
    }
    final body = _decode(res.body);
    return switch (res.statusCode) {
      200 when body['status'] == 'ok' => const HealthResult(HealthStatus.ok),
      401 => const HealthResult(HealthStatus.unauthorized),
      503 => const HealthResult(HealthStatus.tokenNotConfigured),
      _ => HealthResult(HealthStatus.serverError, 'HTTP ${res.statusCode} ${body['message'] ?? ''}'.trim()),
    };
  }

  /// 1枚送る。送信前にファイルが消えた場合は FileSystemException を投げる。
  Future<UploadResult> upload(Candidate file, {required String sha256, required String batch}) async {
    final request = http.MultipartRequest('POST', _endpoint('/api/upload'))
      ..headers.addAll(_auth)
      ..fields['batch'] = batch
      ..fields['sha256'] = sha256
      ..fields['filename'] = file.name
      ..fields['modified_at'] = '${file.mtimeMs}'
      ..files.add(await http.MultipartFile.fromPath('file', file.path, filename: file.name));

    final http.Response res;
    try {
      final streamed = await _client.send(request).timeout(uploadTimeout);
      res = await http.Response.fromStream(streamed).timeout(uploadTimeout);
    } on FileSystemException {
      rethrow;
    } on Exception catch (e) {
      return UploadResult(UploadOutcome.networkError, message: _describe(e));
    }

    final body = _decode(res.body);
    final status = body['status'] as String?;
    final message = (body['message'] as String?) ?? '';
    final code = res.statusCode;
    final UploadOutcome outcome;
    if ((code == 200 || code == 201) && _acceptedStatuses.contains(status)) {
      outcome = UploadOutcome.accepted;
    } else if (code == 401) {
      outcome = UploadOutcome.unauthorized;
    } else if (code >= 400 && code < 500) {
      outcome = UploadOutcome.rejected;
    } else {
      outcome = UploadOutcome.serverError;
    }
    return UploadResult(outcome, serverStatus: status, message: message.isEmpty ? 'HTTP $code' : message);
  }

  static Map<String, dynamic> _decode(String body) {
    try {
      final v = jsonDecode(body);
      return v is Map<String, dynamic> ? v : const {};
    } on FormatException {
      return const {};
    }
  }

  static String _describe(Exception e) => switch (e) {
    TimeoutException() => 'タイムアウト',
    SocketException(:final message, :final osError) => osError?.message ?? message,
    http.ClientException(:final message) => message,
    _ => e.toString(),
  };
}
