import 'dart:io';

import 'package:path/path.dart' as p;

import 'config.dart';
import 'database.dart';

class Candidate {
  const Candidate({required this.path, required this.size, required this.mtimeMs});

  final String path;
  final int size;
  final int mtimeMs;

  String get name => p.basename(path);
  String get key => sentKey(path, size, mtimeMs);
}

/// 送信対象の条件。定期・手動は from = 基準日時、一括は指定した期間を渡す。
class ScanCriteria {
  const ScanCriteria({this.from, this.to, this.excludeSent = true});

  final DateTime? from;
  final DateTime? to;
  final bool excludeSent;
}

/// 拡張子と、ダウンロード途中・隠しファイルの除外（仕様書 5章）
bool isEligibleName(String name) {
  final lower = name.toLowerCase();
  if (lower.startsWith('.') || lower.startsWith(pendingFilePrefix)) return false;
  if (partialFileSuffixes.any(lower.endsWith)) return false;
  return imageExtensions.contains(p.extension(lower));
}

/// [dir] 直下（サブフォルダは含めない）から送信対象を更新日時の古い順に返す。
Future<List<Candidate>> scanCandidates(
  Directory dir,
  ScanCriteria criteria, {
  required Set<String> sentKeys,
  required DateTime now,
}) async {
  final graceLimit = now.subtract(recentFileGrace);
  final result = <Candidate>[];
  await for (final entity in dir.list(followLinks: false)) {
    if (entity is! File || !isEligibleName(p.basename(entity.path))) continue;
    final FileStat stat;
    try {
      stat = await entity.stat();
    } on FileSystemException {
      continue; // 一覧を取った後に削除されたなど
    }
    final modified = stat.modified;
    if (modified.isAfter(graceLimit)) continue;
    if (criteria.from != null && modified.isBefore(criteria.from!)) continue;
    if (criteria.to != null && modified.isAfter(criteria.to!)) continue;
    final c = Candidate(path: entity.path, size: stat.size, mtimeMs: modified.millisecondsSinceEpoch);
    if (criteria.excludeSent && sentKeys.contains(c.key)) continue;
    result.add(c);
  }
  result.sort((a, b) => a.mtimeMs != b.mtimeMs ? a.mtimeMs.compareTo(b.mtimeMs) : a.path.compareTo(b.path));
  return result;
}
