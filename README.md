# Nightdrop

サブのAndroidスマホでブラウザからダウンロードした画像を、同じローカルネットワーク上の画像ビュワー（Flask製の Local Image Viewer）へ無線で送るアプリです。有線でコピーする手間をなくし、夜の充電中にまとめて送ることを目的にしています。

詳しい仕様は [docs/nightdrop-spec.md](docs/nightdrop-spec.md) を参照してください。

## 現在の実装状況

| 機能 | 状況 |
| --- | --- |
| 設定画面（サーバーURL・トークン・基準日時・接続テスト・権限の許可） | 実装済み |
| 「今すぐ送る」による手動送信 | 実装済み |
| 送信済みの記録・二重送信の防止・batch名の管理・中断後の再開・失敗した画像の再送 | 実装済み |
| WorkManagerによる定期送信（1日1回・週1回） | 未実装（設定項目のみあり） |
| 実行結果の通知・履歴画面 | 未実装 |
| 期間を指定した一括送信 | 送信処理のみ実装済み。画面は未実装 |

## 動作の概要

- `/storage/emulated/0/Download` の直下にある jpg・jpeg・png・webp・gif を送ります。サブフォルダは対象外です。
- 基準日時（初回起動時の日時。設定画面で変更できます）より前に更新された画像は送りません。
- ダウンロード途中のファイル（`.crdownload` など）と、更新されてから60秒以内のファイルは送りません。
- 一度送った画像は記録しておき、二度送りません。サーバー側でも SHA-256 で重複を判定するため、送り直しても二重には保存されません。
- 1回の送信を「バッチ」とし、実行日の `YYYY-MM-DD` を名前にして、サーバーのそのフォルダへ保存します。同じ日に2回目のバッチを送った場合は `YYYY-MM-DD_2` のようになります。
- 通信エラーなどで途中で止まった場合は、次回の送信で同じバッチ名のまま続きを送ります。

## 必要な環境

- 送信元：Android 13以上のスマホ
- 送信先：[Local Image Viewer](https://github.com/hungrykirby/local-image-viewer)（Flask）を動かすPC（Raspberry PiまたはWindows）。スマホと同じローカルネットワークにあること
- 開発用PC：Flutter SDK、Android SDK、JDK（Android Studioを入れると揃います）。`flutter doctor` で確認できます

## 使い方

### 1. 受信側（Local Image Viewer）の準備

1. Local Image Viewer の `.env.example` を `.env` にコピーし、`VIEWER_UPLOAD_TOKEN` に共有トークンを設定してサーバーを起動します。
2. サーバーを動かすPCのIPアドレスを、ルーターのDHCP予約などで固定します。
3. 夜間に送るため、サーバーを常駐させ、PCがスリープしないようにします。

詳しくは [Local Image Viewer の README](https://github.com/hungrykirby/local-image-viewer#readme) の「Nightdropからの画像受信」を参照してください。

### 2. アプリのインストール

スマホの開発者オプションでUSBデバッグを有効にし、PCにつないで実行します。

```sh
flutter pub get
flutter run --release
```

APKを作ってスマホにコピーし、直接インストールすることもできます。

```sh
flutter build apk --release
```

### 3. アプリの設定

1. 右上の設定ボタンから設定画面を開きます。
2. サーバーURL（例：`http://192.168.x.x:5000`）と、受信側と同じトークンを入力します。
3. 「接続テスト」で「接続できました」と表示されることを確認します。
4. 「全ファイルへのアクセス」の「許可する」から、システムの画面で許可します。
5. 「保存」を押してホーム画面に戻り、「今すぐ送る」を押します。

## 開発

```sh
flutter analyze
flutter test                         # 単体テスト
tool/flask_integration_test.sh       # 実際の Local Image Viewer との結合テスト
```

- 結合テストは、隣のフォルダにある `../local-image-viewer` を一時フォルダへコピーし、`127.0.0.1:5099` で起動してから実行します。初回は `.dart_tool/flask_venv` にPythonの仮想環境を作り、Flaskをインストールします。別の場所にある場合は `VIEWER_SRC` で指定してください。
- `flutter test` だけを実行した場合、結合テストはスキップされます。

| 場所 | 内容 |
| --- | --- |
| `lib/src/send_pipeline.dart` | 送信処理（定期・手動・一括で共通） |
| `lib/src/scanner.dart` | 送信する画像の判定 |
| `lib/src/viewer_api.dart` | Local Image Viewer の `/api/health`・`/api/upload` の呼び出し |
| `lib/src/database.dart` | 送信済みの記録・実行履歴・同時実行を防ぐロック（sqflite） |
| `lib/src/settings.dart` | 設定の保存とサーバーURLの確認 |
| `lib/src/ui/` | 画面 |
| `docs/nightdrop-spec.md` | 仕様書 |

## 通信の安全性について

このアプリは、信頼できる自宅などのローカルネットワークでの利用を想定しています。

- 受信側がHTTPで待ち受けるため、トークンと画像は暗号化されずに送られます。同じネットワークにいる機器からは読み取れる可能性があります。
- AndroidではHTTP通信を許可する設定にしています（`android/app/src/main/res/xml/network_security_config.xml`）。その代わり、アプリの設定でHTTPの送信先に指定できるのは、プライベートIPアドレス（`192.168.x.x`、`10.x.x.x`、`172.16`〜`172.31`）と `.local` の名前に限っています。
- 外出先のWi-Fiに、受信側と同じIPアドレスの機器があると、そこへ送ってしまう可能性があります。サブスマホは自宅以外のWi-Fiにつながないでください。
