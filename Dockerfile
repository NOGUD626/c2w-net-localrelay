# PoC: c2w-net-localrelay 用カスタム rootfs (riscv64/Alpine 3.20 + 追加パッケージ)
#
# 既定の riscv64/alpine:3.20 だと busybox 一式しか入っておらず、
# ・curl と CA 証明書がなく HTTPS が ssl_client エラー
# ・nano / vim も無く編集が辛い
# ・dig / host が無く DNS デバッグも辛い
# ので、最初から一式入れた rootfs を作る。
#
# ビルド: build-image.sh が docker buildx で QEMU 経由 (linux/riscv64) ビルドする。
#
# サイズ目安: 約 +13MB (apk add 後の rootfs 増分。out.wasm は 52MB → 約 65MB)

FROM riscv64/alpine:3.20

RUN apk add --no-cache \
    # --- HTTPS / TLS 修復 ---
    ca-certificates \
    curl \
    # --- テキストエディタ ---
    nano \
    vim \
    # --- DNS デバッグ (dig / host / nslookup) ---
    bind-tools \
    # --- ネットワーク全般 (ip / ss / tc / ping の拡張版) ---
    iputils \
    iproute2 \
    # --- 教育用シェル / ページャ ---
    bash \
    less

# シェルを bash に切り替え (任意。busybox ash のままがよければ削除)
# シェル変更は環境変数で見せるだけにして、起動コマンドはデフォルトのままにする
ENV SHELL=/bin/bash

# 動作確認用に PATH 等は標準のまま
