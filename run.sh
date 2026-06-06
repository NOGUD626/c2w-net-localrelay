#!/usr/bin/env bash
#
# c2w-net (ホスト側ユーザー空間 TCP/IP スタック) と
# 静的配信 (serve.mjs) を同時に起動する。
#
# Ctrl+C で両方止まる。
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly C2W_NET="${SCRIPT_DIR}/bin/c2w-net"
readonly SERVE="${SCRIPT_DIR}/serve.mjs"
readonly WS_ADDR="${WS_ADDR:-127.0.0.1:8888}"
readonly HTTP_PORT="${PORT:-8080}"

# --- 事前チェック (guard clause) ---
if [ ! -x "$C2W_NET" ]; then
  echo "エラー: c2w-net が未ビルドです。./build-c2w-net.sh を先に実行してください。" >&2
  exit 1
fi
if [ ! -f "$SCRIPT_DIR/htdocs/out.wasm" ]; then
  echo "エラー: htdocs/out.wasm がありません。" >&2
  echo "  container2wasm-demo/htdocs/out.wasm への symlink を期待しています。" >&2
  exit 1
fi
if ! command -v node >/dev/null 2>&1; then
  echo "エラー: node が見つかりません。Node.js をインストールしてください。" >&2
  exit 1
fi

echo "==> c2w-net 起動 (listen ws://${WS_ADDR})"
"$C2W_NET" --listen-ws "${WS_ADDR}" &
NET_PID=$!

# 終了時に c2w-net を確実に殺す
cleanup() {
  echo
  echo "==> 停止"
  if kill -0 "$NET_PID" 2>/dev/null; then
    kill "$NET_PID" 2>/dev/null || true
    wait "$NET_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

# c2w-net の listen を少しだけ待つ
sleep 1

# 起動確認 (失敗してたら早期エラー)
if ! kill -0 "$NET_PID" 2>/dev/null; then
  echo "エラー: c2w-net が起動直後に終了しました。--debug 付きで原因を確認してください。" >&2
  exit 1
fi

echo "==> 静的配信 起動 (http://127.0.0.1:${HTTP_PORT}/)"
echo "    ブラウザで開くと自動で ws://${WS_ADDR} に接続します"
PORT="$HTTP_PORT" node "$SERVE"
