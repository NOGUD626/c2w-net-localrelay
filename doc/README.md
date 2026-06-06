# c2w-net-localrelay 設計ドキュメント

本リポジトリは **ローカル loopback で動く PoC** だが、その先 (VPS で複数ユーザーに公開、
外部 API 利用、教育用途への展開等) を考えると検討事項が多数ある。

ここには **「実装はまだ、でも考えはある」**フェーズの設計メモを集約している。
ローカル PoC を動かすだけならルート [`../README.md`](../README.md) で十分。

## 文書一覧

| 文書 | 主題 | 想定読者 |
|---|---|---|
| [multi-tenant-architecture.md](multi-tenant-architecture.md) | 複数接続を捌くための 3 段アーキテクチャ (Caddy/nginx + broker + c2w-net pool)、broker 実装スケッチ、c2w-net 改修パッチ | VPS 上で複数ユーザーに公開したい人 |
| [vps-deployment.md](vps-deployment.md) | VPS スペック見積もり (実測ベース)、致命的問題のリスト、必須改修チェックリスト、推奨 VPS プロバイダ | VPS デプロイの責任者 |
| [external-api-access.md](external-api-access.md) | ブラウザ Linux から Notion / GitHub / OpenAI / Claude API 等を叩く具体例、できないこと、認証情報の扱い注意 | 教育デモを設計する人、API 連携を考える人 |

## 読む順序

### 「VPS に置きたい」が動機の人

1. [vps-deployment.md](vps-deployment.md) で **現状そのまま VPS に置くと何が起きるか** と **必要なリソース** を把握
2. [multi-tenant-architecture.md](multi-tenant-architecture.md) で **複数接続を分離する具体的なアーキ** と **実装スケッチ** を確認
3. ルートの [README.md](../README.md) に戻って **ローカルで PoC が動く構成** を見直し、改修箇所を特定

### 「教育デモを作りたい」が動機の人

1. [external-api-access.md](external-api-access.md) で **何ができて何ができないか** を確認
2. [vps-deployment.md](vps-deployment.md) で **必要なスペック** と **公開時のリスク** を把握
3. [multi-tenant-architecture.md](multi-tenant-architecture.md) で **同時受講人数に応じた構成** を選ぶ
   (5〜30 人 → 簡易版、それ以上 → broker パターン)

### 「とりあえずアーキだけ理解したい」

[multi-tenant-architecture.md](multi-tenant-architecture.md) 冒頭の ASCII 図と「鍵となる分業」だけ読めば全体像が掴める。

## ステータス

| 文書 | 状態 | 検証 |
|---|---|---|
| multi-tenant-architecture.md | 📝 設計提案 | broker 実装は未着手、c2w-net 改修パッチも未適用 |
| vps-deployment.md | 📝 設計提案 + 一部実測 | メモリ使用量 (idle 21MB) は Mac arm64 で実測済、VPS デプロイは未実施 |
| external-api-access.md | ✅ 仕様確認済 | `curl https://api.github.com/zen` は PoC で実証済、他 API は理論上同じ経路 |

## 次のアクション候補 (もし継続するなら)

- [ ] `c2w-net` に `--subnet`, `--no-localhost-nat`, `--exit-on-disconnect` フラグを実装してパッチ PR (c2w-src/cmd/c2w-net/main.go)
- [ ] broker (Go) の最小実装 (150 行程度) を `cmd/c2w-broker/` 配下に追加
- [ ] 簡易版 (ip_hash プール) の docker-compose.yml + Caddyfile を作って Hetzner CPX11 で動作確認
- [ ] 接続先 allowlist を gvisor の `Forwards` で実装
- [ ] abuse 検出ログ集計の最小例 (Loki + Grafana)

これらは別リポジトリ `c2w-net-broker` を切るのも選択肢。
