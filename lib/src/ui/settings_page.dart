import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../settings.dart';
import '../viewer_api.dart';
import 'format.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.settingsStore});

  final SettingsStore settingsStore;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> with WidgetsBindingObserver {
  final _formKey = GlobalKey<FormState>();
  final _urlController = TextEditingController();
  final _tokenController = TextEditingController();
  Settings? _settings;
  bool _tokenVisible = false;
  bool _testing = false;
  String? _testMessage;
  PermissionStatus? _storageStatus;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _urlController.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  /// システムの許可画面から戻ったときに権限の状態を更新する
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _loadPermission();
  }

  Future<void> _load() async {
    final s = await widget.settingsStore.load();
    _urlController.text = s.serverUrl;
    _tokenController.text = s.token;
    setState(() => _settings = s);
    await _loadPermission();
  }

  Future<void> _loadPermission() async {
    final status = await Permission.manageExternalStorage.status;
    if (mounted) setState(() => _storageStatus = status);
  }

  Settings _current() => _settings!.copyWith(
    serverUrl: _urlController.text.trim(),
    token: _tokenController.text.trim(),
  );

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    await widget.settingsStore.save(_current());
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  Future<void> _testConnection() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _testing = true;
      _testMessage = null;
    });
    final s = _current();
    final api = ViewerApi(baseUrl: s.serverUrl, token: s.token);
    final result = await api.health();
    api.close();
    if (mounted) {
      setState(() {
        _testing = false;
        _testMessage = result.message;
      });
    }
  }

  Future<void> _pickBaseline() async {
    final current = _settings!.baseline;
    final date = await showDatePicker(
      context: context,
      initialDate: current,
      firstDate: DateTime(2000),
      lastDate: DateTime.now(),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(current));
    if (time == null) return;
    setState(() {
      _settings = _settings!.copyWith(
        baseline: DateTime(date.year, date.month, date.day, time.hour, time.minute),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = _settings;
    return Scaffold(
      appBar: AppBar(
        title: const Text('設定'),
        actions: [TextButton(onPressed: s == null ? null : _save, child: const Text('保存'))],
      ),
      body: s == null
          ? const Center(child: CircularProgressIndicator())
          : Form(
              key: _formKey,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  TextFormField(
                    controller: _urlController,
                    decoration: const InputDecoration(
                      labelText: 'サーバーURL',
                      hintText: 'http://192.168.x.x:5000',
                    ),
                    keyboardType: TextInputType.url,
                    validator: (v) => validateServerUrl(v ?? ''),
                  ),
                  TextFormField(
                    controller: _tokenController,
                    decoration: InputDecoration(
                      labelText: 'トークン',
                      suffixIcon: IconButton(
                        icon: Icon(_tokenVisible ? Icons.visibility_off : Icons.visibility),
                        onPressed: () => setState(() => _tokenVisible = !_tokenVisible),
                      ),
                    ),
                    obscureText: !_tokenVisible,
                    validator: (v) => (v ?? '').trim().isEmpty ? 'トークンを入力してください' : null,
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      OutlinedButton(
                        onPressed: _testing ? null : _testConnection,
                        child: const Text('接続テスト'),
                      ),
                      const SizedBox(width: 12),
                      if (_testing) const SizedBox.square(dimension: 16, child: CircularProgressIndicator()),
                      if (_testMessage != null) Expanded(child: Text(_testMessage!)),
                    ],
                  ),
                  const Divider(height: 32),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('実行間隔'),
                    trailing: DropdownButton<RunInterval>(
                      value: s.interval,
                      items: [
                        for (final v in RunInterval.values) DropdownMenuItem(value: v, child: Text(v.label)),
                      ],
                      onChanged: (v) => setState(() => _settings = s.copyWith(interval: v)),
                    ),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Wi-Fi接続中のみ'),
                    value: s.wifiOnly,
                    onChanged: (v) => setState(() => _settings = s.copyWith(wifiOnly: v)),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('充電中のみ'),
                    value: s.chargingOnly,
                    onChanged: (v) => setState(() => _settings = s.copyWith(chargingOnly: v)),
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('基準日時'),
                    subtitle: const Text('これより前に更新された画像は定期送信・手動送信で送りません'),
                    trailing: Text(formatDateTime(s.baseline)),
                    onTap: _pickBaseline,
                  ),
                  const Divider(height: 32),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('全ファイルへのアクセス'),
                    subtitle: Text(switch (_storageStatus) {
                      null => '確認中',
                      PermissionStatus.granted => '許可済み',
                      _ => '未許可（ダウンロードフォルダの画像を読むために必要です）',
                    }),
                    trailing: _storageStatus == PermissionStatus.granted
                        ? null
                        : OutlinedButton(
                            onPressed: () => Permission.manageExternalStorage.request(),
                            child: const Text('許可する'),
                          ),
                  ),
                ],
              ),
            ),
    );
  }
}
