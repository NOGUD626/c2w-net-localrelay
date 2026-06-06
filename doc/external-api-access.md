# ブラウザ Linux から外部 API へのアクセス

> 状態: 仕様確認 + curl 動作確認済。本リポジトリの PoC で実証された通信能力の
> 応用範囲を整理したもの。

## 結論を先に

| やりたいこと | 可否 | 補足 |
|---|---|---|
| Notion API を叩く | ⭕ | curl + Bearer Token で完全動作 |
| GitHub API を叩く | ⭕ | PoC で `api.github.com/zen` 検証済 |
| OpenAI API を叩く | ⭕ | TLS 1.3 + 大きめレスポンスストリーム OK |
| 任意の HTTPS REST API | ⭕ | CA 検証込み、CORS 制約なし |
| WebSocket クライアント (例: 取引所) | ⭕ | `wscat` 等 (`apk add ws`) を入れれば |
| SSH / SCP | ⭕ | `apk add openssh-client` で |
| **Notion の Web UI (notion.so) を見る** | ❌ | React SPA は busybox 環境でレンダリング不可 |
| ブラウザ自動化 (Selenium / Playwright) | ❌ | RISC-V Alpine 向け chromium パッケージなし |

## なぜ動くか

PoC で実証された経路:

```
[ブラウザ内 Linux]
   curl                          ← Alpine 3.20 + ca-certificates + curl
   ↓ TCP/443
[c2w-net (gvisor-tap-vsock)]      ← TCP/TLS パススルー (TLS 終端しない)
   ↓ socket()
[ホスト Mac/Linux]
   ↓ outbound HTTPS
[インターネット]
   ↓ TLS 1.3 + 証明書検証
[api.notion.com / api.github.com / api.openai.com]
```

**c2w-net は L4 終端**であって TLS は中継するだけ。コンテナ内の curl がエンドツーエンドで
TLS handshake を行い、サーバ証明書を `/etc/ssl/certs/` の CA バンドルで検証する。

→ プロキシ経由のような MITM の懸念なし、CORS 制約なし、API 認証 (Bearer Token / OAuth / mTLS)
   は全部素直に使える。

## 具体例

### Notion API

```sh
# ワークスペース情報
export NOTION_TOKEN="ntn_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"

curl -sS \
  -H "Authorization: Bearer $NOTION_TOKEN" \
  -H "Notion-Version: 2022-06-28" \
  https://api.notion.com/v1/users/me

# ページ検索
curl -sS -X POST \
  -H "Authorization: Bearer $NOTION_TOKEN" \
  -H "Notion-Version: 2022-06-28" \
  -H "Content-Type: application/json" \
  -d '{"query":"PoC"}' \
  https://api.notion.com/v1/search

# ページ取得
curl -sS \
  -H "Authorization: Bearer $NOTION_TOKEN" \
  -H "Notion-Version: 2022-06-28" \
  https://api.notion.com/v1/pages/<page_id>

# ページ追加
curl -sS -X POST \
  -H "Authorization: Bearer $NOTION_TOKEN" \
  -H "Notion-Version: 2022-06-28" \
  -H "Content-Type: application/json" \
  -d '{
    "parent": {"page_id": "<parent_id>"},
    "properties": {"title": [{"text": {"content": "From WASM Linux"}}]}
  }' \
  https://api.notion.com/v1/pages
```

### GitHub API

```sh
# 認証不要なエンドポイント (PoC で動作実証済)
curl -sS https://api.github.com/zen
# → "Avoid administrative distraction."

# 認証ありエンドポイント
export GH_TOKEN="ghp_..."
curl -sS \
  -H "Authorization: Bearer $GH_TOKEN" \
  -H "Accept: application/vnd.github+json" \
  https://api.github.com/user

# リポジトリ一覧
curl -sS \
  -H "Authorization: Bearer $GH_TOKEN" \
  https://api.github.com/user/repos?per_page=10

# Gist 作成
curl -sS -X POST \
  -H "Authorization: Bearer $GH_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "description": "From WASM Linux",
    "public": false,
    "files": {"hello.txt": {"content": "Hello from c2w-net!"}}
  }' \
  https://api.github.com/gists
```

### OpenAI API (Chat Completions)

```sh
export OPENAI_API_KEY="sk-..."

# Chat Completions (ストリーミングなし)
curl -sS https://api.openai.com/v1/chat/completions \
  -H "Authorization: Bearer $OPENAI_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gpt-4o-mini",
    "messages": [{"role": "user", "content": "Say hello in one short sentence."}]
  }' | jq '.choices[0].message.content'

# ストリーミング (Server-Sent Events)
curl -N https://api.openai.com/v1/chat/completions \
  -H "Authorization: Bearer $OPENAI_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gpt-4o-mini",
    "messages": [{"role": "user", "content": "Count to 5 slowly."}],
    "stream": true
  }'
```

> `apk add jq` で JSON パース可、`apk add curl-doc` でマニュアル参照可。

### Anthropic Claude API

```sh
export ANTHROPIC_API_KEY="sk-ant-..."

curl -sS https://api.anthropic.com/v1/messages \
  -H "x-api-key: $ANTHROPIC_API_KEY" \
  -H "anthropic-version: 2023-06-01" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "claude-sonnet-4-5",
    "max_tokens": 1024,
    "messages": [{"role": "user", "content": "Hello"}]
  }'
```

### Slack Webhook

```sh
curl -sS -X POST \
  -H "Content-Type: application/json" \
  -d '{"text": "Hello from inside a WASM Linux!"}' \
  https://hooks.slack.com/services/T.../B.../...
```

## できないこと

### ❌ Web UI のブラウズ (notion.so / google.com 等)

ブラウザ内 Linux に**ブラウザは入っていない** (busybox + curl + nano だけ)。`https://www.notion.so/`
を curl で叩くと React SPA の HTML が返るだけで、JS 実行 = ページ描画は無理。

回避案 (PoC スコープ外):
1. **テキストブラウザ** (w3m / lynx / links) を `apk add` — ただし SPA は描画できない
2. **headless chromium** — RISC-V Alpine 用パッケージが存在しないため実質不可
3. **「API でやる」アプローチに切り替える** ← 現実解

### ❌ WebRTC

データチャネルは TCP/UDP の上に立つので gvisor-tap-vsock 越しでも理屈上は通るが、
STUN/TURN サーバとのネゴ、ICE candidates 収集等の挙動は非確認 (PoC スコープ外)。

### ❌ DNS over HTTPS (DoH) のサーバ用途

クライアントとしては叩けるが、`/etc/resolv.conf` 経由の名前解決は **gvisor-tap-vsock 内蔵の
forwarder** が処理するので、DoH 化はそこで切れる。

## 認証情報の取り扱い注意

ブラウザ内 Linux はサンドボックス内で動くが、以下の点に注意:

| 注意点 | 詳細 |
|---|---|
| **シェル履歴に残る** | `export NOTION_TOKEN=...` は xterm-pty のスクロールバックに残る。タブを閉じれば消えるが、開いている間は誰でも履歴を見られる |
| **`/tmp` も rootfs 内** | 機密ファイルを `/tmp` に書いてもメモリに保持される (タブ閉じれば消える) |
| **HTTPS の中身は安全** | TLS handshake はゲスト ↔ 相手サーバの間でエンドツーエンド。c2w-net は TLS の中身を見ない |
| **ホスト Mac/Linux からは見えない** | WASM サンドボックス内なので、ホストのプロセスからは中身を覗けない |
| **public な VPS に置いた場合** | broker 経由で他人と分離していれば他ユーザーからは見えない。ただし VPS 運営者は WS バイナリ (= L2 フレーム) を傍受しようと思えば可能 |

**実運用ルール**:
1. 短命トークン (24h 有効など) を使う
2. 強い権限のトークンは入れない (例: GitHub admin:org は避ける)
3. デモが終わったら **トークンを必ず revoke**
4. 共有 VPS の場合は **エンドツーエンドの暗号化を信頼できる API のみ**

## ユースケース例

ブラウザ内 Linux + 外部 API の組み合わせで面白いユースケース:

| シナリオ | 何ができる |
|---|---|
| **コマンドライン教材** | 受講生が `curl` で API を叩く演習。鯖いらずでブラウザだけ |
| **CLI ツールのデモ** | `gh`, `aws`, `gcloud` 等を `apk add` して試せる (ただし大きい) |
| **API スクリプト試作** | サーバ立てずに `bash + curl + jq` で API ロジック検証 |
| **AI チャット端末** | `curl` で OpenAI / Anthropic API、`jq` で整形して対話 |
| **Slack/Discord Bot 試作** | Webhook POST を `bash` でラフ実装 → 後で Cloudflare Workers 等に移植 |
| **教育用 Linux 環境** | 学習者が API を呼ぶ Linux 体験。教師側のサーバ管理コストゼロ |

## 関連ドキュメント

- [multi-tenant-architecture.md](multi-tenant-architecture.md) — 複数接続を捌くアーキ
- [vps-deployment.md](vps-deployment.md) — VPS スペックと必須対策
