#!/usr/bin/env bash
# Flask ビュワー（../local-image-viewer）を一時フォルダで起動し、結合テストを実行する。
#   tool/flask_integration_test.sh
# 環境変数:
#   VIEWER_SRC  ビュワーのフォルダ（初期値: ../local-image-viewer）
#   PORT        待ち受けポート（初期値: 5099）
set -euo pipefail

APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VIEWER_SRC="${VIEWER_SRC:-$APP_DIR/../local-image-viewer}"
PORT="${PORT:-5099}"
VENV="$APP_DIR/.dart_tool/flask_venv"
TOKEN="integration-$RANDOM$RANDOM"

if [[ ! -x "$VENV/bin/python" ]]; then
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install --quiet -r "$VIEWER_SRC/requirements.txt"
fi

# ビュワーは server.py の隣に folders.json・library/・data/ を書くため、コピーして動かす
WORK="$(mktemp -d)"
cp "$VIEWER_SRC/server.py" "$VIEWER_SRC/receiver.py" "$VIEWER_SRC/index.html" "$WORK/"

cleanup() {
  [[ -n "${SERVER_PID:-}" ]] && kill "$SERVER_PID" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

(cd "$WORK" && VIEWER_UPLOAD_TOKEN="$TOKEN" VIEWER_LIBRARY_DIR="$WORK/library" VIEWER_HOST=127.0.0.1 VIEWER_PORT="$PORT" \
  exec "$VENV/bin/python" server.py >"$WORK/server.log" 2>&1) &
SERVER_PID=$!

for _ in $(seq 1 50); do
  curl -sf -H "Authorization: Bearer $TOKEN" "http://127.0.0.1:$PORT/api/health" >/dev/null && break
  sleep 0.2
done

NIGHTDROP_FLASK_URL="http://127.0.0.1:$PORT" \
NIGHTDROP_FLASK_TOKEN="$TOKEN" \
NIGHTDROP_FLASK_LIBRARY="$WORK/library" \
  flutter test "$APP_DIR/test/integration" "$@" || { echo '--- server.log'; cat "$WORK/server.log"; exit 1; }
