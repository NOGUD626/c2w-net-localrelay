#!/usr/bin/env bash
#
# Dockerfile を docker buildx (QEMU エミュ経由 linux/riscv64) でビルドして、
# c2w で WASM 化、htdocs/out.wasm の symlink を切り替える。
#
# 注意: RISC-V エミュで apk add が走るので、初回は 5〜15 分かかる。
# 2 回目以降は buildx キャッシュで高速化する。
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly TAG="c2w-net-localrelay:alpine-net"
readonly OUT="${SCRIPT_DIR}/htdocs/out.wasm.alpine-net"
readonly DOCKERFILE="${SCRIPT_DIR}/Dockerfile"
# c2w バイナリは本リポジトリの bin/c2w を使う (./build-c2w.sh で生成)
readonly C2W="${C2W:-${SCRIPT_DIR}/bin/c2w}"

# --- 事前チェック (guard clause) ---
if [ ! -x "$C2W" ]; then
  echo "エラー: c2w が見つかりません: $C2W" >&2
  echo "  先に ./build-c2w.sh を実行してください。" >&2
  exit 1
fi
if [ ! -f "$DOCKERFILE" ]; then
  echo "エラー: Dockerfile が見つかりません: $DOCKERFILE" >&2
  exit 1
fi
if ! docker info >/dev/null 2>&1; then
  echo "エラー: Docker デーモンに接続できません。Docker Desktop を起動してください。" >&2
  exit 1
fi

# --- binfmt (QEMU エミュ) セットアップ ---
# Mac arm64 から linux/riscv64 イメージをビルドするには QEMU が要る。
# Docker Desktop で binfmt_misc に riscv64 ハンドラが登録されているかを確認。
if ! docker buildx inspect --bootstrap 2>/dev/null | grep -qE "Platforms:.*linux/riscv64"; then
  echo "==> RISC-V binfmt (QEMU) をセットアップ"
  docker run --privileged --rm tonistiigi/binfmt --install riscv64
fi

# --- 1. Docker イメージビルド (riscv64 ターゲット) ---
echo "==> riscv64 用 Alpine イメージビルド (QEMU エミュ + apk add)"
echo "    タグ: $TAG"
echo "    初回は数分〜十数分かかります"
docker buildx build \
    --platform=linux/riscv64 \
    --tag "$TAG" \
    --load \
    --file "$DOCKERFILE" \
    "$SCRIPT_DIR"

# --- 2. c2w で WASM 化 ---
echo "==> $TAG を WASM 化"
echo "    出力: $OUT"
mkdir -p "$(dirname "$OUT")"
start_ts="$(date +%s)"
DOCKER_BUILDKIT=1 "$C2W" --target-arch=riscv64 "$TAG" "$OUT"
elapsed="$(( $(date +%s) - start_ts ))"
echo "==> c2w 変換完了 (${elapsed}s)"

# --- 3. htdocs/out.wasm の symlink を切り替え ---
echo "==> htdocs/out.wasm の symlink を ${TAG##*:} 版に切り替え"
rm -f "$SCRIPT_DIR/htdocs/out.wasm"
ln -s "out.wasm.alpine-net" "$SCRIPT_DIR/htdocs/out.wasm"

echo "==> 完了"
ls -lh "$OUT"
ls -la "$SCRIPT_DIR/htdocs/out.wasm"
