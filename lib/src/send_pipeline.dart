import 'dart:io';

import 'package:crypto/crypto.dart';

import 'config.dart';
import 'database.dart';
import 'scanner.dart';
import 'settings.dart';
import 'viewer_api.dart';

/// 一括送信（仕様書 7章）の指定
class BulkRequest {
  const BulkRequest({required this.from, this.to, this.resend = false});

  final DateTime from;
  final DateTime? to;
  final bool resend;
}

class SendProgress {
  const SendProgress({required this.done, required this.total});

  final int done;
  final int total;
}

class RunSummary {
  const RunSummary({
    required this.status,
    this.runId,
    this.batch,
    this.total = 0,
    this.sent = 0,
    this.duplicate = 0,
    this.failed = 0,
    this.message,
  });

  /// 別の実行が動いていたため何もしなかった
  const RunSummary.busy() : this(status: null, message: '別の送信が実行中です');

  /// null は busy（runs に記録しない）
  final RunStatus? status;
  final int? runId;
  final String? batch;
  final int total;
  final int sent;
  final int duplicate;
  final int failed;
  final String? message;

  bool get isBusy => status == null;
}

/// 定期・手動・一括で共通の送信処理（仕様書 6章）。
/// WorkManager のバックグラウンド isolate からも呼ぶため、画面の状態に依存しない。
class SendPipeline {
  SendPipeline({
    required this.db,
    required this.settings,
    ViewerApi Function(Settings settings)? apiFactory,
    DateTime Function()? clock,
  }) : _apiFactory = apiFactory ?? _defaultApi,
       _now = clock ?? DateTime.now;

  final AppDatabase db;
  final Settings settings;
  final ViewerApi Function(Settings settings) _apiFactory;
  final DateTime Function() _now;

  static ViewerApi _defaultApi(Settings s) => ViewerApi(baseUrl: s.serverUrl, token: s.token);

  /// 定期・手動の対象（基準日時以降、未送信）
  ScanCriteria get regularCriteria => ScanCriteria(from: settings.baseline);

  static ScanCriteria bulkCriteria(BulkRequest r) =>
      ScanCriteria(from: r.from, to: r.to, excludeSent: !r.resend);

  Future<List<Candidate>> findCandidates(ScanCriteria criteria) async {
    final dir = Directory(settings.sourceDir);
    if (!await dir.exists()) return const [];
    return scanCandidates(dir, criteria, sentKeys: await db.sentKeys(), now: _now());
  }

  /// [bulk] は trigger が bulk のときだけ渡す。
  /// [timeBudget] を過ぎたら途中で区切り、次回の実行で続きを送る。
  Future<RunSummary> run({
    required RunTrigger trigger,
    BulkRequest? bulk,
    Duration? timeBudget,
    bool Function()? isCancelled,
    void Function(SendProgress progress)? onProgress,
  }) async {
    assert((trigger == RunTrigger.bulk) == (bulk != null));
    final startedAt = _now();
    final owner = '${trigger.name}-${startedAt.microsecondsSinceEpoch}';
    if (!await db.tryAcquireLock(owner, startedAt, lockStaleAfter)) {
      return const RunSummary.busy();
    }
    try {
      return await _run(trigger, bulk, startedAt, owner, timeBudget, isCancelled, onProgress);
    } finally {
      await db.releaseLock(owner);
    }
  }

  Future<RunSummary> _run(
    RunTrigger trigger,
    BulkRequest? bulk,
    DateTime startedAt,
    String owner,
    Duration? timeBudget,
    bool Function()? isCancelled,
    void Function(SendProgress progress)? onProgress,
  ) async {
    final batch = await _batchName(trigger, startedAt);
    final runId = await db.startRun(
      batch: batch,
      trigger: trigger,
      startedAt: startedAt,
      rangeFrom: bulk?.from,
      rangeTo: bulk?.to,
      resend: bulk?.resend ?? false,
    );
    var sent = 0, duplicate = 0, failed = 0, total = 0;

    Future<RunSummary> finish(RunStatus status, [String? message]) async {
      await db.updateRunCounts(runId, sent: sent, duplicate: duplicate, failed: failed);
      await db.finishRun(runId, status: status, finishedAt: _now(), message: message);
      return RunSummary(
        status: status,
        runId: runId,
        batch: batch,
        total: total,
        sent: sent,
        duplicate: duplicate,
        failed: failed,
        message: message,
      );
    }

    final urlError = validateServerUrl(settings.serverUrl);
    if (urlError != null || settings.token.isEmpty) {
      return await finish(RunStatus.failed, urlError ?? 'トークンが設定されていません');
    }

    final api = _apiFactory(settings);
    try {
      final health = await api.health();
      if (!health.isOk) return await finish(RunStatus.interrupted, health.message);

      final files = await findCandidates(bulk == null ? regularCriteria : bulkCriteria(bulk));
      total = files.length;
      final deadline = timeBudget == null ? null : startedAt.add(timeBudget);
      onProgress?.call(SendProgress(done: 0, total: total));

      for (final (i, file) in files.indexed) {
        if (isCancelled?.call() ?? false) return await finish(RunStatus.interrupted, '中止しました');
        if (deadline != null && _now().isAfter(deadline)) {
          return await finish(RunStatus.interrupted, '実行時間の上限に達したため、残りは次回送ります');
        }
        await db.heartbeatLock(owner, _now());

        final UploadResult result;
        final String hash;
        try {
          hash = (await sha256.bind(File(file.path).openRead()).first).toString();
          result = await api.upload(file, sha256: hash, batch: batch);
        } on FileSystemException {
          continue; // 送信前に削除されたなど。失敗として記録しない（仕様書 11章）
        }

        switch (result.outcome) {
          case UploadOutcome.accepted:
            await db.recordSent(
              path: file.path,
              size: file.size,
              mtimeMs: file.mtimeMs,
              sha256: hash,
              batch: batch,
              result: result.serverStatus!,
              sentAt: _now(),
            );
            result.serverStatus == 'saved' ? sent++ : duplicate++;
          case UploadOutcome.rejected:
            await db.addFailure(runId, file.path, '${result.serverStatus ?? '-'}: ${result.message}');
            failed++;
          case UploadOutcome.unauthorized:
            return await finish(RunStatus.interrupted, 'トークンが違います。設定を確認してください');
          case UploadOutcome.serverError:
            return await finish(RunStatus.interrupted, 'サーバーエラー：${result.message}');
          case UploadOutcome.networkError:
            return await finish(RunStatus.interrupted, '接続できませんでした：${result.message}');
        }
        await db.updateRunCounts(runId, sent: sent, duplicate: duplicate, failed: failed);
        onProgress?.call(SendProgress(done: i + 1, total: total));
      }
      return await finish(RunStatus.done);
    } on Exception catch (e) {
      return await finish(RunStatus.failed, e.toString());
    } finally {
      api.close();
    }
  }

  /// 前回の定期・手動送信が途中で止まっていればその batch 名、
  /// なければ実行日の YYYY-MM-DD（使用済みなら _2, _3 …）。一括送信は常に新しい名前。
  Future<String> _batchName(RunTrigger trigger, DateTime now) async {
    if (trigger != RunTrigger.bulk) {
      final last = await db.latestRun(triggers: {RunTrigger.scheduled, RunTrigger.manual});
      if (last != null && last.status.isResumable) return last.batch;
    }
    final date = '${now.year.toString().padLeft(4, '0')}-'
        '${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final used = await db.batchNamesOn(date);
    if (!used.contains(date)) return date;
    for (var n = 2;; n++) {
      final name = '${date}_$n';
      if (!used.contains(name)) return name;
    }
  }
}
