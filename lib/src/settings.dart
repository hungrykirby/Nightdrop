import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import 'config.dart';

enum RunInterval {
  daily(Duration(days: 1), '1日1回'),
  weekly(Duration(days: 7), '週1回');

  const RunInterval(this.period, this.label);

  final Duration period;
  final String label;
}

class Settings {
  const Settings({
    required this.serverUrl,
    required this.token,
    required this.interval,
    required this.wifiOnly,
    required this.chargingOnly,
    required this.baseline,
    required this.sourceDir,
  });

  final String serverUrl;
  final String token;
  final RunInterval interval;
  final bool wifiOnly;
  final bool chargingOnly;

  /// この日時より前に更新された画像は定期送信・手動送信で送らない
  final DateTime baseline;
  final String sourceDir;

  bool get isServerConfigured => serverUrl.isNotEmpty && token.isNotEmpty;

  Settings copyWith({
    String? serverUrl,
    String? token,
    RunInterval? interval,
    bool? wifiOnly,
    bool? chargingOnly,
    DateTime? baseline,
    String? sourceDir,
  }) {
    return Settings(
      serverUrl: serverUrl ?? this.serverUrl,
      token: token ?? this.token,
      interval: interval ?? this.interval,
      wifiOnly: wifiOnly ?? this.wifiOnly,
      chargingOnly: chargingOnly ?? this.chargingOnly,
      baseline: baseline ?? this.baseline,
      sourceDir: sourceDir ?? this.sourceDir,
    );
  }
}

/// 設定値を shared_preferences に保存する。
/// WorkManager のバックグラウンド isolate からも最新値を読めるよう、
/// isolate ごとにキャッシュを持たない SharedPreferencesAsync を使う。
class SettingsStore {
  SettingsStore([SharedPreferencesAsync? prefs])
    : _prefs = prefs ?? SharedPreferencesAsync();

  final SharedPreferencesAsync _prefs;

  static const _serverUrl = 'server_url';
  static const _token = 'token';
  static const _interval = 'interval';
  static const _wifiOnly = 'wifi_only';
  static const _chargingOnly = 'charging_only';
  static const _baselineMs = 'baseline_ms';
  static const _sourceDir = 'source_dir';

  /// 初回は基準日時に現在日時を保存する（仕様書 4章）
  Future<Settings> load({DateTime Function() now = DateTime.now}) async {
    var baselineMs = await _prefs.getInt(_baselineMs);
    if (baselineMs == null) {
      baselineMs = now().millisecondsSinceEpoch;
      await _prefs.setInt(_baselineMs, baselineMs);
    }
    final intervalName = await _prefs.getString(_interval);
    return Settings(
      serverUrl: await _prefs.getString(_serverUrl) ?? '',
      token: await _prefs.getString(_token) ?? '',
      interval: RunInterval.values.firstWhere(
        (v) => v.name == intervalName,
        orElse: () => RunInterval.daily,
      ),
      wifiOnly: await _prefs.getBool(_wifiOnly) ?? true,
      chargingOnly: await _prefs.getBool(_chargingOnly) ?? true,
      baseline: DateTime.fromMillisecondsSinceEpoch(baselineMs),
      sourceDir: await _prefs.getString(_sourceDir) ?? defaultSourceDir,
    );
  }

  Future<void> save(Settings s) async {
    await _prefs.setString(_serverUrl, s.serverUrl);
    await _prefs.setString(_token, s.token);
    await _prefs.setString(_interval, s.interval.name);
    await _prefs.setBool(_wifiOnly, s.wifiOnly);
    await _prefs.setBool(_chargingOnly, s.chargingOnly);
    await _prefs.setInt(_baselineMs, s.baseline.millisecondsSinceEpoch);
    await _prefs.setString(_sourceDir, s.sourceDir);
  }
}

/// サーバーURLを検証し、問題があればエラーメッセージを返す。
///
/// トークンを平文の HTTP で送るため、http の場合は宛先を
/// プライベートIPアドレスと .local の名前に限る（インターネットへ送らない）。
String? validateServerUrl(String value) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null || !uri.hasAuthority || uri.host.isEmpty) {
    return 'URLの形式が正しくありません（例：http://192.168.x.x:$defaultServerPort）';
  }
  if (uri.scheme == 'https') return null;
  if (uri.scheme != 'http') return 'http または https で指定してください';
  if (!isLocalNetworkHost(uri.host)) {
    return 'http の場合はローカルネットワークのアドレス（192.168.x.x など）を指定してください';
  }
  return null;
}

bool isLocalNetworkHost(String host) {
  if (host.toLowerCase().endsWith('.local')) return true;
  final ip = InternetAddress.tryParse(host);
  if (ip == null || ip.type != InternetAddressType.IPv4) return false;
  final b = ip.rawAddress;
  return b[0] == 10 ||
      b[0] == 127 ||
      (b[0] == 172 && b[1] >= 16 && b[1] <= 31) ||
      (b[0] == 192 && b[1] == 168);
}
