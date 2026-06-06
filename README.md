# c2w-net-localrelay — ブラウザの Linux から外と通信する PoC

[container2wasm](https://github.com/container2wasm/container2wasm) を使うと、ブラウザの中で
**本物の Linux** (Alpine + RISC-V) が動く。ただし生のままだとオフラインで、外には出られない。

本プロジェクトは **ホスト Mac で `c2w-net` を常駐**させ、ブラウザ内 Linux の L2 イーサネットフレームを
WebSocket で受けて gvisor-tap-vsock で終端し、**Mac の本物 socket() で外に出す**ことを実証する PoC。

ブラウザの中で `curl https://api.github.com/zen` が CA 証明書検証込みで通る。`ping 8.8.8.8` も通る。

```
$ curl -sS https://api.github.com/zen
Avoid administrative distraction.
```

## アーキテクチャ

```
[ブラウザ http://127.0.0.1:8080]
  ├ index.html / out.wasm / ws-delegate.js  ← serve.mjs が配信
  │
  ├ ゲスト Linux (Alpine 3.20 / RISC-V + curl/nano/dig/bash)
  │   └ eth0 (virtio-net) → TinyEMU が L2 フレームをバイト列で取り出す
  │
  └ ws-delegate.js が L2 フレームを WebSocket バイナリで送信
       │
       ↓ ws://127.0.0.1:8888
[c2w-net --listen-ws 127.0.0.1:8888]    ← Mac ネイティブバイナリ (Go)
  ├ gvisor-tap-vsock で L2 終端
  │   ├ ゲートウェイ 192.168.127.1 (内蔵 DNS / DHCP も兼任)
  │   ├ ゲスト DHCP 動的リース 192.168.127.X
  │   └ ICMP / TCP / UDP 全部終端
  └ Mac の本物 socket() で外部接続
       ↓
[インターネット]
```

## 前提

| ツール | 用途 | 確認版 |
|---|---|---|
| Go | `c2w` と `c2w-net` をネイティブビルド (`GOTOOLCHAIN=auto` で 1.25 自動取得) | 1.24.6 |
| Docker Desktop | `c2w` が `docker buildx` で rootfs を作る | 27.5.1 |
| Node.js | COOP/COEP 付き静的配信 (`serve.mjs`) | v23 |
| ブラウザ | `SharedArrayBuffer` 対応 (Chrome 推奨) | macOS / Chrome |
| git | container2wasm 本家を clone | 任意 |

検証環境: M1 Mac (macOS 14) — フル動作 (HTTPS / ICMP / DNS / nano / apk 全部 OK)。

## セットアップ (clone から起動まで)

### 1. clone

```bash
git clone https://github.com/NOGUD626/c2w-net-localrelay.git
cd c2w-net-localrelay
```

### 2. c2w (container → WASM 変換) を Mac ネイティブビルド

```bash
./build-c2w.sh
# - container2wasm v0.8.4 を c2w-src/ に clone
# - Docker 27 系向けパッチ (docker save --platform を除去) を適用
# - go build -o bin/c2w ./cmd/c2w
```

### 3. c2w-net (ホスト中継スタック) を Mac ネイティブビルド

```bash
./build-c2w-net.sh
# - 同じ c2w-src/ の cmd/c2w-net/ をビルド
# - go build -o bin/c2w-net ./cmd/c2w-net
# 約 16MB の darwin/arm64 バイナリ
```

### 4. カスタム rootfs を WASM 化 (初回 5〜15 分)

```bash
./build-image.sh
# - docker buildx で Dockerfile (Alpine 3.20 + curl/nano/dig/bash 等) を linux/riscv64 ビルド
#   ★初回 QEMU エミュ + apk add で時間かかる、2 回目以降は buildx キャッシュで速い
# - c2w で WASM 化 → htdocs/out.wasm.alpine-net (約 94MB) を生成
# - htdocs/out.wasm の symlink を切り替え
```

### 5. 起動

```bash
./run.sh
# ==> c2w-net 起動 (listen ws://127.0.0.1:8888)
# ==> 静的配信 起動 (http://127.0.0.1:8080/)
```

ブラウザで **http://127.0.0.1:8080/** を開く → 約 30 秒で `/ #` プロンプト → 左ペインのボタンで演習。

## ブラウザ内 Linux で試せる操作

```sh
# === 起動確認 ===
uname -a                        # RISC-V Linux 6.1.0
ip addr                         # eth0 に 192.168.127.X (c2w-net の DHCP)

# === ネット確認 ===
cat /etc/resolv.conf            # nameserver 192.168.127.1
dig google.com                  # Server: 192.168.127.1#53 (gvisor 内蔵 DNS)
ping -c 3 8.8.8.8               # ICMP も通る
curl -sS http://example.com/    # HTTP plain
curl -sS https://api.github.com/zen   # ★HTTPS が CA 検証込みで通る

# === エディタ / パッケージ管理 ===
nano /tmp/hello.txt             # nano 8.0 で編集
apk info | head -20             # インストール済パッケージ一覧
apk add jq                      # 追加インストール (リポジトリにも HTTPS で繋がる)
```

## ディレクトリ構成

```
c2w-net-localrelay/
├── README.md
├── .gitignore
├── Dockerfile                  # Alpine 3.20 + 追加パッケージ
├── build-c2w.sh                # c2w 本体ビルド (container2wasm を c2w-src/ に clone)
├── build-c2w-net.sh            # c2w-net (中継スタック) ビルド
├── build-image.sh              # Docker rootfs → WASM
├── run.sh                      # c2w-net + serve.mjs を起動
├── serve.mjs                   # COOP/COEP ヘッダ付き静的配信
├── bin/                        # ★生成物 (.gitignore)
│   ├── c2w                     #   container → WASM 変換ツール
│   └── c2w-net                 #   gvisor-tap-vsock ベースの中継
├── c2w-src/                    # ★生成物 (.gitignore) container2wasm 本家 clone
└── htdocs/                     # ブラウザ配信ルート
    ├── index.html              # 2 ペイン演習 UI
    ├── worker.js               # WASI 実行ワーカー
    ├── ws-delegate.js          # L2 ↔ WebSocket ブリッジ
    ├── stack.js / stack-worker.js / wasi-util.js / worker-util.js
    ├── coi-serviceworker.js    # COOP/COEP を Service Worker で付与
    ├── browser_wasi_shim/      # WASI 実装 (bjorn3/browser_wasi_shim)
    ├── vendor/                 # xterm.js / xterm-pty / addon-fit
    ├── out.wasm.alpine-net     # ★生成物 (.gitignore) c2w 変換結果 約 94MB
    └── out.wasm                # ★生成物 (.gitignore) out.wasm.alpine-net への symlink
```

## カスタマイズ

### 追加パッケージを増やす

`Dockerfile` の `RUN apk add` 行に足して `./build-image.sh` を再実行。

```dockerfile
RUN apk add --no-cache \
    ca-certificates curl nano vim bind-tools iputils iproute2 bash less \
    git tmux jq python3   # ← 追加
```

### 別のサブネットや MAC、TLS を使う

`run.sh` の `--listen-ws` 引数や `c2w-net` フラグを編集。

```bash
./bin/c2w-net --listen-ws 127.0.0.1:8888 --debug   # debug ログ ON
./bin/c2w-net --listen-ws :8888 --enable-tls --ws-cert ... --ws-key ...
```

## 制約 / ハマりどころ

- **公式は "tested only on Linux"**: c2w-net 本家 README が明記。本 PoC で M1 Mac での動作は実証済だが、
  予期しないプラットフォーム依存の挙動が将来出る可能性。
- **ループバック束縛必須**: `run.sh` のデフォルトは `--listen-ws 127.0.0.1:8888` (loopback のみ)。
  これを `:8888` にすると **オープンプロキシ**として LAN 内 / 外部から踏み台にされる。
- **DNS リゾルバ**: gvisor-tap-vsock 内蔵の forwarder が動き、最終的に **Mac のシステムリゾルバ**
  にフォワードされる。VPN や社内 DNS も透過する。
- **MAC アドレス**: `ws-delegate.js` が接続ごとにランダム MAC を生成。`c2w-net` の DHCP は
  動的リースで応答する (`192.168.127.X`)。
- **WS が EOF で切れる現象**: タブの visibility 変化や WebWorker の一時停止で WebSocket が
  落ちることがある。`c2w-net.log` に `cannot receive packets ... EOF` として記録される。
  reload で復活する。
- **node のバージョン**: `serve.mjs` は ESM なので Node.js >= v18 が要る。nvm デフォルトが古い場合は
  `nvm use 23` 等の事前設定が必要。

## VPS で公開する場合 (絶対やってはいけないこと + 改修方針)

`run.sh` の構成をそのまま VPS に置くと **致命的に危険**。c2w-net の NAT 設定に
`192.168.127.254 → 127.0.0.1` が入っているので、ブラウザのユーザーが **VPS の localhost**
(Docker daemon、Redis、内部 API、Grafana 等)に丸ごとアクセスできてしまう。

最低限の改修ポイント:

| 対策 | 修正箇所 |
|---|---|
| ✅ NAT から `127.0.0.1` を削除 | c2w-net main.go の `NAT` を `map[string]string{}` に |
| ✅ TLS 終端 (wss://) | Caddy / nginx 前段、もしくは `--enable-tls` |
| ✅ 認証 (basic / OAuth / Cloudflare Access) | 前段の Caddy / nginx で WS upgrade 前にチェック |
| ✅ ユーザーごとに subnet 分離 | broker (自前 Go) が接続ごとに別 `--subnet` で c2w-net を spawn |
| ✅ rate limit / 同時接続数制限 | 前段リバプロ + broker のスロットプール |
| ✅ abuse 対策 (接続先 allowlist) | `Forwards` で許可先のみ通過 (c2w-net 改修) |

VPS スペック目安: メモリ 2GB で同時 15〜20 人、4GB で 50 人前後 (c2w-net 1 接続 ≒ 21〜60MB RSS)。

## 参考

- 上位プロジェクト: [container2wasm](https://github.com/container2wasm/container2wasm) (CNCF Sandbox)
- ベースの考え方: [container2wasm-demo (オフライン版)](https://github.com/NOGUD626/container2wasm-demo)
- 中継スタック: [gvisor-tap-vsock](https://github.com/containers/gvisor-tap-vsock)
  (Podman Machine が macOS/Windows でデフォルト採用、本番実績あり)
- 公式 networking 例: `c2w-src/examples/networking/websocket/` (clone 後)

## ライセンス / 出典

- 変換ツール: [container2wasm](https://github.com/container2wasm/container2wasm) (Apache-2.0)
- 中継スタック: [gvisor-tap-vsock](https://github.com/containers/gvisor-tap-vsock) (Apache-2.0)
- ブラウザ実行アセット: [xterm.js](https://github.com/xtermjs/xterm.js) /
  [xterm-pty](https://github.com/mame/xterm-pty) /
  [browser_wasi_shim](https://github.com/bjorn3/browser_wasi_shim)
- 生成される `out.wasm` には Bochs / TinyEMU / Linux kernel / runc / BusyBox / Alpine が含まれます
  (各ソフトウェアのライセンスに従います)。
