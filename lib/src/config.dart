// 送信対象の判定や通信に使う定数（仕様書 5章・6章）

const defaultSourceDir = '/storage/emulated/0/Download';

/// 送信対象の拡張子（小文字で比較する）
const imageExtensions = {'.jpg', '.jpeg', '.png', '.webp', '.gif'};

/// ダウンロード途中・一時ファイルの拡張子
const partialFileSuffixes = ['.crdownload', '.tmp'];

/// Android の MediaStore が書き込み途中に付けるファイル名の接頭辞
const pendingFilePrefix = '.pending-';

/// 更新されてからこの時間が経っていないファイルはダウンロード中とみなして送らない
const recentFileGrace = Duration(seconds: 60);

const healthTimeout = Duration(seconds: 10);
const uploadTimeout = Duration(seconds: 60);

/// WorkManager の1回の実行時間の上限（約10分）より短く切り上げる
const scheduledTimeBudget = Duration(minutes: 9);

/// ロックの最終更新からこの時間が経てば、前の実行は異常終了したとみなす。
/// 1枚の送信（最大 uploadTimeout）より十分長くする。
const lockStaleAfter = Duration(minutes: 3);

/// Flask ビュワーの初期ポート
const defaultServerPort = 5000;
