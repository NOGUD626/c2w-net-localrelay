#!/usr/bin/env bash
#
# container2wasm を clone して c2w をネイティブビルドする。
# macOS 向けの c2w バイナリは配布されていないため Go でビルドする。
#
# あわせて Docker 27 以前向けのパッチを当てる:
#   c2w v0.8.4 は内部で `docker save --platform=linux/<arch>` を使うが、
#   docker save の --platform は Docker 28.0 で追加されたフラグなので、
#   27 系では "unknown flag: --platform" で変換が失敗する。
#   直前の `docker pull --platform` で正しいアーキを取得済みのため、
#   この行は安全に除去できる。
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly C2W_VERSION="v0.8.4"
readonly SRC_DIR="${SCRIPT_DIR}/c2w-src"
readonly BIN="${SCRIPT_DIR}/bin/c2w"
readonly REPO="https://github.com/ktock/container2wasm.git"

# --- 事前チェック (guard clause) ---
if ! command -v go >/dev/null 2>&1; then
  echo "エラー: go が見つかりません (Go 1.21+ が必要)。" >&2
  exit 1
fi
if ! command -v git >/dev/null 2>&1; then
  echo "エラー: git が見つかりません。" >&2
  exit 1
fi

# --- 1. clone (未取得なら) ---
if [ ! -d "$SRC_DIR" ]; then
  echo "==> clone container2wasm ${C2W_VERSION}"
  git clone --depth 1 --branch "$C2W_VERSION" "$REPO" "$SRC_DIR"
fi

# --- 2. Docker 27 以前向けパッチ (docker save の --platform 行を除去) ---
readonly MAIN_GO="${SRC_DIR}/cmd/c2w/main.go"
readonly PLATFORM_LINE='saveArgs = append(saveArgs, "--platform=linux/"+targetarch)'
if grep -qF "$PLATFORM_LINE" "$MAIN_GO"; then
  echo "==> パッチ適用: docker save の --platform を除去 (Docker 27 対応)"
  perl -0777 -i -pe \
    's/\tif targetarch != "" \{\n\t\tsaveArgs = append\(saveArgs, "--platform=linux\/"\+targetarch\)\n\t\}\n//' \
    "$MAIN_GO"
  # 検証: 確実に除去できたか (冪等性チェック)
  if grep -qF "$PLATFORM_LINE" "$MAIN_GO"; then
    echo "エラー: パッチ適用に失敗。$MAIN_GO を手動修正してください。" >&2
    exit 1
  fi
fi

# --- 3. go build (darwin ネイティブバイナリ) ---
mkdir -p "${SCRIPT_DIR}/bin"
echo "==> go build c2w"
GOTOOLCHAIN=auto go build -C "$SRC_DIR" -o "$BIN" ./cmd/c2w
echo "==> 完了: $BIN"
"$BIN" --version || true
