import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../database.dart';
import '../send_pipeline.dart';
import '../settings.dart';
import 'format.dart';
import 'settings_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.db, required this.settingsStore});

  final AppDatabase db;
  final SettingsStore settingsStore;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  Settings? _settings;
  RunRecord? _lastRun;
  int? _pendingCount;
  bool _hasStorageAccess = false;
  SendProgress? _progress;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final settings = await widget.settingsStore.load();
    final lastRun = await widget.db.latestRun();
    final hasAccess = await Permission.manageExternalStorage.isGranted;
    final pipeline = SendPipeline(db: widget.db, settings: settings);
    final pending = hasAccess ? (await pipeline.findCandidates(pipeline.regularCriteria)).length : null;
    if (!mounted) return;
    setState(() {
      _settings = settings;
      _lastRun = lastRun;
      _hasStorageAccess = hasAccess;
      _pendingCount = pending;
    });
  }

  Future<void> _sendNow() async {
    final settings = _settings;
    if (settings == null) return;
    setState(() {
      _sending = true;
      _progress = null;
    });
    final summary = await SendPipeline(db: widget.db, settings: settings).run(
      trigger: RunTrigger.manual,
      onProgress: (p) {
        if (mounted) setState(() => _progress = p);
      },
    );
    if (!mounted) return;
    setState(() => _sending = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_describe(summary))));
    await _refresh();
  }

  String _describe(RunSummary s) {
    if (s.isBusy) return s.message!;
    final counts = '送信 ${s.sent}・重複 ${s.duplicate}・失敗 ${s.failed}';
    return s.message == null ? '${s.status!.label}：$counts' : '${s.status!.label}：$counts\n${s.message}';
  }

  Future<void> _openSettings() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => SettingsPage(settingsStore: widget.settingsStore)),
    );
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final settings = _settings;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Nightdrop'),
        actions: [IconButton(icon: const Icon(Icons.settings), tooltip: '設定', onPressed: _openSettings)],
      ),
      body: settings == null
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _refresh,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  if (!settings.isServerConfigured)
                    const _Notice('設定画面でサーバーURLとトークンを設定してください'),
                  if (!_hasStorageAccess)
                    const _Notice('設定画面で「全ファイルへのアクセス」を許可してください'),
                  _LastRunCard(run: _lastRun),
                  ListTile(
                    title: const Text('未送信の画像'),
                    subtitle: Text('基準日時 ${formatDateTime(settings.baseline)} 以降'),
                    trailing: Text(
                      _pendingCount == null ? '-' : '$_pendingCount 枚',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (_sending) ...[
                    LinearProgressIndicator(
                      value: _progress == null || _progress!.total == 0
                          ? null
                          : _progress!.done / _progress!.total,
                    ),
                    const SizedBox(height: 8),
                    Text(_progress == null ? '接続を確認しています' : '${_progress!.done} / ${_progress!.total} 枚'),
                  ] else
                    FilledButton.icon(
                      icon: const Icon(Icons.send),
                      label: const Text('今すぐ送る'),
                      onPressed: settings.isServerConfigured && _hasStorageAccess ? _sendNow : null,
                    ),
                ],
              ),
            ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.errorContainer,
      child: ListTile(
        leading: Icon(Icons.warning_amber, color: scheme.onErrorContainer),
        title: Text(text, style: TextStyle(color: scheme.onErrorContainer)),
      ),
    );
  }
}

class _LastRunCard extends StatelessWidget {
  const _LastRunCard({required this.run});

  final RunRecord? run;

  @override
  Widget build(BuildContext context) {
    final r = run;
    return Card(
      child: ListTile(
        title: const Text('前回の実行'),
        subtitle: r == null
            ? const Text('まだ実行していません')
            : Text(
                '${formatDateTime(r.startedAt)}（${r.trigger.label}）${r.status.label}\n'
                'batch ${r.batch}・送信 ${r.sent}・重複 ${r.duplicate}・失敗 ${r.failed}'
                '${r.message == null ? '' : '\n${r.message}'}',
              ),
        isThreeLine: r != null,
      ),
    );
  }
}
