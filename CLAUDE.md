# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project status

Nightdrop is a personal Flutter (Android-only) app. The full spec lives in `docs/nightdrop-spec.md` (Japanese) and is the source of truth — read it before implementing anything. Spec steps 1–2 are implemented (as of 2026-10-06). WorkManager scheduling, notifications, the history screen and the bulk-send UI are not done yet.

The receiving server is a separate, already-implemented project at `../local-image-viewer/` (Flask: `server.py` routes, `receiver.py` logic). Its `README.md` section "API（Nightdrop向け）" is the authoritative wire contract; if it disagrees with the Nightdrop spec, the server wins. Don't change the server to fit the app without the user's consent.

Implementation order (spec section 14): settings + manual send → sent-file records / baseline datetime / batch naming / resend → WorkManager scheduling → notifications + history screen → date-range bulk send.

## What the app does

Uploads images that a secondary Android phone downloaded into `/storage/emulated/0/Download` (top level only, no subfolders) to a self-hosted Flask random-slideshow viewer on the LAN, one image per `POST /api/upload`. It usually runs as a WorkManager periodic task (every 24h or 7 days, by default only on Wi-Fi while charging). Users can also send manually, or bulk-send everything in a date range.

- Package / applicationId: `com.hungrykirby.nightdrop`
- Target: Android 13+. Distributed by `flutter install` or a sideloaded APK only (no store)
- Key packages: `workmanager`, `http`, `sqflite`, `crypto`, `permission_handler`, `flutter_local_notifications`, `shared_preferences`

## Commands

```bash
flutter pub get
flutter analyze
flutter test                                   # all tests
flutter test test/path/to_test.dart            # single file
flutter test --plain-name "test description"   # single test by name
tool/flask_integration_test.sh                 # integration tests against the real Flask viewer (see below)
flutter run --release                          # run on USB-connected phone
flutter build apk --release && flutter install
flutter doctor                                 # check SDK / toolchain
```

- Unit tests use real files in a temp directory, an ffi SQLite file DB (`openTestDb` in `test/helpers.dart`) and `FakeViewer`, a `MockClient` that mimics the Flask contract. Inject `clock` and `apiFactory` into `SendPipeline` rather than relying on wall time.
- `tool/flask_integration_test.sh` creates a venv at `.dart_tool/flask_venv`, copies `../local-image-viewer` into a temp dir, starts it on `127.0.0.1:5099` with a random token, and runs `test/integration/`. Without the script, those tests are skipped.
- `compileSdk` is pinned to 37 in `android/app/build.gradle.kts`, because `permission_handler_android` 14 requires it.

## Architecture rules that span multiple components

Code lives in `lib/src/`. `send_pipeline.dart` is the single entry point for every trigger. It uses `scanner.dart` (file selection), `viewer_api.dart` (HTTP), `database.dart` (sqflite, including the lock) and `settings.dart` (shared_preferences + URL validation). `ui/` holds the screens.

Three triggers share one send pipeline: `scheduled` (WorkManager), `manual` (the "今すぐ送る" button) and `bulk` (date-range send). Only their file selection and runtime context differ:

| | scheduled / manual | bulk |
|---|---|---|
| File filter | mtime ≥ baseline datetime, and not in `sent_files` | mtime within [from, to], **ignores the baseline**; `sent_files` exclusion only when the "resend" switch is OFF |
| Batch name | reuse the interrupted batch's name if one exists, otherwise `YYYY-MM-DD` (`_2`, `_3`… on same-day collision) | always a new name, same rule |
| Execution limit | ~10 min WorkManager limit → stop partway, resume on the next run | foreground (`setForeground` + progress notification), no time limit, cancellable |
| Run conditions | Wi-Fi / charging constraints from settings | ignored; show a confirmation dialog if not on Wi-Fi |

Shared invariants:
- **A single lock** prevents scheduled, manual and bulk runs from running at the same time.
- **Common exclusions** for every trigger: extensions other than jpg/jpeg/png/webp/gif (case-insensitive), `.crdownload`, `.tmp`, `.pending-*`, dotfiles, and files with mtime within the last 60 seconds.
- **Sent-file identity** is `(path, size, mtime)`, the `sent_files` primary key. `mtime` is UNIX **milliseconds**, both locally and in the request.
- **Per-file HTTP handling**: compute SHA-256 (lowercase hex) → multipart POST with `Authorization: Bearer <token>` and fields `file`, `batch`, `sha256`, `filename`, `modified_at` (60s timeout). Field names must match the server exactly, because it silently ignores unknown fields. Read the result from the JSON `status` field.
  - `201 saved`, `200 duplicate`, `200 deleted` (trashed in the viewer, never re-stored): record in `sent_files` with that status
  - other `4xx` (`400 invalid`, `413 too_large`, `422 corrupted`): record in `failures` and continue (retried on the next run)
  - `401`, `5xx` or a network error: abort the batch and save progress (401 also notifies the user to check the token; `503` means the server has no `VIEWER_UPLOAD_TOKEN` set)
  - file unreadable or deleted before sending: skip silently
- Server-side constraints: batch names must match `\w[\w\-]{0,63}`; dedup is by SHA-256 only, across all batches; the default size limit is 50 MB per file.
- Run `/api/health` before each batch. If it fails, end the run as `interrupted`, so the next run resumes the same batch name.
- Every run writes a `runs` row with its trigger, status (`running`/`done`/`interrupted`/`failed`) and counts. Schema: spec section 8.
- Settings (URL, token, interval, constraints, baseline datetime) live in `shared_preferences`. On first launch the baseline is set to "now". Any settings change must cancel and re-register the periodic task.
- The WorkManager callback runs in a separate background isolate. Pipeline code must not depend on UI state. For the same reason, the lock is a heartbeat row in the `run_lock` table (stale after `lockStaleAfter`), not an in-memory flag, and settings use `SharedPreferencesAsync`, which has no per-isolate cache.
- Batch-name collisions are checked only against `sent_files`, so a run that sent nothing does not consume `YYYY-MM-DD`.
- `validateServerUrl` allows `http` only to private IPv4 / `.local` hosts, because the token travels in cleartext. The pipeline re-checks it before sending.

## Android platform setup

- Permissions: `MANAGE_EXTERNAL_STORAGE` (granted from the system settings screen), `POST_NOTIFICATIONS` (runtime), `INTERNET`, the Nearby devices permission for local-network access on Android 17+ (runtime), and an optional battery-optimization exemption prompt.
- Cleartext HTTP: `android/app/src/main/res/xml/network_security_config.xml` permits cleartext for all hosts (`base-config`), so changing the server IP doesn't require a rebuild. This deviates from the spec's domain-scoped example on purpose, with the user's approval. The real guard is `validateServerUrl` (http → private IPv4 / `.local` only); keep the two in sync.
