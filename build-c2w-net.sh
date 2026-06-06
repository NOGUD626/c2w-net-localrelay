#!/usr/bin/env bash
#
# c2w-net (gvisor-tap-vsock ベースのユーザー空間 TCP/IP スタック) を
# macOS ネイティブにビルドする。
#
# 既定では本リポジトリ内の c2w-src/ (./build-c2w.sh が clone) を使う。
# 別の場所を指す場合は C2W_SRC=/path/to/c2w-src ./build-c2w-net.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly OUT="${SCRIPT_DIR}/bin/c2w-net"
readonly C2W_SRC="${C2W_SRC:-${SCRIPT_DIR}/c2w-src}"

# --- 事前チェック (guard clause) ---
if ! command -v go >/dev/null 2>&1; then
  echo "エラー: go が見つかりません。Go (>= 1.24) をインストールしてください。" >&2
  exit 1
fi
if [ ! -d "$C2W_SRC" ]; then
  echo "エラー: c2w-src が見つかりません: $C2W_SRC" >&2
  echo "  先に ./build-c2w.sh を実行して container2wasm 本家を clone してください。" >&2
  echo "  別の場所を使う場合は C2W_SRC=/path/to/c2w-src ./build-c2w-net.sh" >&2
  exit 1
fi
if [ ! -f "$C2W_SRC/cmd/c2w-net/main.go" ]; then
  echo "エラー: cmd/c2w-net/main.go が見つかりません: $C2W_SRC" >&2
  exit 1
fi

mkdir -p "$(dirname "$OUT")"

echo "==> c2w-net をネイティブビルド (darwin/arm64)"
echo "    ソース: $C2W_SRC"
echo "    出力 : $OUT"

cd "$C2W_SRC"
# go.mod が go 1.25 を要求するため GOTOOLCHAIN=auto で自動取得
GOTOOLCHAIN=auto go build -o "$OUT" ./cmd/c2w-net

echo "==> 完了"
ls -lh "$OUT"
