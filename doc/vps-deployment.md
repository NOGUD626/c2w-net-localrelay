# VPS デプロイ — スペック見積もりと必須対策

> 状態: 設計提案 + 実測ベース。本リポジトリの PoC を VPS で公開する場合の参考資料。
> 実デプロイは未実施。

## 結論を先に

| 規模 | 推奨スペック | 月額目安 |
|---|---|---|
| **同時接続 10〜20 人** (内輪 / 教室) | **2 vCPU / 2 GB / 40 GB** | ¥800〜¥1,800 |
| 同時接続 30〜50 人 | 2 vCPU / 4 GB / 80 GB | ¥2,000〜¥4,000 |
| 同時接続 100 人+ | 4 vCPU / 8 GB / 160 GB | ¥4,000〜¥8,000 |

ただし **そのまま VPS に置くと致命的問題**があるので、必須改修 (後述) を入れた上で。

## このまま VPS に置くと何が起きるか

現状の `run.sh` を VPS で動かして `--listen-ws` を外向きにしただけだと、以下が同時に発生する。

### ★ 致命的問題 1: ホストの localhost が誰でも見える

c2w-net のソース (`c2w-src/cmd/c2w-net/main.go`):

```go
NAT: map[string]string{
    "192.168.127.254": "127.0.0.1",   // ← これ
},
```

「ゲストから `192.168.127.254` 宛のパケットは VPS の `127.0.0.1` に NAT」設定。

→ ユーザーが `curl http://192.168.127.254:9000/` で **VPS の localhost:9000 にアクセスできる**。

VPS で動いている以下が全部漏れる:
- Docker daemon (`2375/2376`)
- Redis / PostgreSQL / MySQL の localhost bind
- Grafana / Prometheus / Kibana
- 内部用 HTTP API
- SSH のローカル待ち受け
- メトリクス収集系の HTTP endpoint

### 致命的問題 2: ユーザー同士が L2 で互いに見える

`vn` (= VirtualNetwork) はプロセスに 1 つ。全 WS 接続が同じ仮想 subnet (192.168.127.0/24) に乗る。

```
[ユーザー A] 192.168.127.5
[ユーザー B] 192.168.127.6   ← arp-scan で A から発見可能、互いに ping/TCP 接続可能
[ユーザー C] 192.168.127.7
```

ARP spoofing で他人の通信を横取りもできる。

### 致命的問題 3: オープン HTTP/SOCKS プロキシ化

c2w-net 以降は VPS のホスト OS の `socket()` で外に出ていく。

- スパムメール送信 → VPS の IP が IP ブロックリスト入り
- スクレイピング踏み台
- マイニング、DDoS への加担
- abuse 報告の責任は **運営者**

### 致命的問題 4: ホスト側 NAT セッションテーブル共有

gvisor-tap-vsock の接続追跡テーブルが全ユーザー共有。1 人が大量に接続を張ると他人の通信に影響。

### 副次問題: キャパシティ

Subnet が `/24` なので **DHCP リース上限 250 個**。それ以上の同時接続は IP 払い出しでコケる。

## 必須改修チェックリスト

VPS 公開前に以下が全部済んでいないと公開禁止。

### Tier 0: これがないと開けてはいけない

- [ ] **c2w-net の NAT から `127.0.0.1` を削除** (`--no-localhost-nat` 改修)
- [ ] **TLS 終端 (wss://)** — Caddy / nginx で Let's Encrypt、または `--enable-tls`
- [ ] **認証** — Cloudflare Access / basic auth / OAuth / 署名トークンのいずれか
- [ ] **`--listen-ws 127.0.0.1:8888`** で loopback bind、外向きは Caddy / nginx 経由のみ

### Tier 1: 公開規模次第で必須

- [ ] **ユーザーごとに subnet 分離** — broker で接続ごとに別 c2w-net spawn (see [multi-tenant-architecture.md](multi-tenant-architecture.md))
- [ ] **接続数 cap** — `net.LimitListener` か broker の slot 数で
- [ ] **rate limit / 帯域制限** — Caddy の `rate_limit` プラグイン、または nginx の `limit_req` / `limit_conn`

### Tier 2: 不特定多数公開ならさらに必須

- [ ] **接続先 allowlist** — gvisor の Forwards で許可した宛先 IP/Port のみ通過 (c2w-net 改修要)
- [ ] **abuse 検出** — c2w-net の `--debug` ログを集めて不審パターンを監視 (大量同一宛先、SMTP/25 への接続試行など)
- [ ] **CDN / WAF** — Cloudflare WAF + Bot Fight Mode 等
- [ ] **CAPTCHA** — 接続前に Cloudflare Turnstile / hCaptcha 等で人間判定

## メモリ実測 + 収容力試算

### 実測 (Mac arm64)

| 構成要素 | RSS |
|---|---|
| **c2w-net 1 インスタンス (idle)** | **21 MB** ← 実測 |
| OS (systemd + kernel + sshd) | 200〜350 MB |
| Caddy (TLS + 静的 + WS proxy) | 40〜80 MB |
| broker (自前 Go) | 30〜50 MB |
| `out.wasm` page cache (94 MB を一度配信) | 〜100 MB |
| バーストマージン (swap 回避) | 200 MB |
| **基礎コスト合計** | **約 700 MB** |

### active 補正

c2w-net は idle で 21MB だが、通信中は gvisor の TCP セッションテーブル + ARP/DHCP リース + 受信バッファで膨らむ。

→ **active 想定で 60 MB / 1 接続** が安全側の見積もり。

### スペック別の収容力

```
(メモリ合計 − 基礎 700 MB) ÷ 60 MB ≒ 同時接続可能数
```

| メモリ | 収容力 (実用) | 適性 |
|---|---|---|
| 1 GB | 5 人 | 個人専用 |
| **2 GB** | **15〜20 人** | **小教室・内輪・PoC ✅** |
| 4 GB | 50 人前後 | 大教室・社内勉強会 |
| 8 GB | 100 人+ | 公開デモ・カンファ |
| 16 GB | 250 人 (subnet /24 上限) | フル稼働 |

## メモリ以外のリソース要件

| 項目 | 必要量 | 補足 |
|---|---|---|
| **vCPU** | 1 vCPU でギリ、**2 vCPU 推奨** | c2w-net 自体は軽いが、20 人同時通信で総 CPU 30〜50% |
| **ディスク** | 10 GB あれば余裕 | out.wasm 94MB + バイナリ + OS で実質 5 GB |
| **帯域** | 月 1 TB あれば余裕 | out.wasm 配信は初回のみ (ブラウザキャッシュ)、通常使用は数十 MB/月/人 |
| **swap** | 1〜2 GB は設定する | バーストで OOM 回避。Hetzner 等は自分で `swapfile` 作る |
| **オープンファイル数 (`ulimit -n`)** | 65536 推奨 | 接続数 × 4 (WS + upstream + 2 for buffer) を上回るように |

## 推奨 VPS プロバイダ (2 GB / 2 vCPU クラス)

### コスパ重視 (海外 OK)

| プロバイダ | プラン | 月額 | 補足 |
|---|---|---|---|
| **Hetzner Cloud** | CPX11 (2vCPU/2GB/40GB) | **€4.55 ≒ ¥800** | コスパ最強。EU/US リージョン。性能十分 |
| Contabo | Cloud VPS 10 (3vCPU/8GB/100GB) | €5.50 ≒ ¥1,000 | メモリ多め、ただしバースト性能控えめ |

### 日本リージョン (低レイテンシ重視)

| プロバイダ | プラン | 月額 | 補足 |
|---|---|---|---|
| **Vultr** | Regular Cloud Compute (1vCPU/2GB) | $12 | 東京リージョンあり |
| **Linode** | Nanode 2GB (1vCPU/2GB) | $12 | 東京リージョンあり |
| **AWS Lightsail** | 2GB (2vCPU/2GB/60GB) | $10 | 東京あり、AWS 系連携が楽 |
| **さくらのVPS** | 2G (2vCPU/2GB/100GB) | ¥1,738 | 国内、サポート日本語 |
| **ConoHa VPS** | 2GB (3vCPU/2GB/100GB) | ¥968 | 国内、料金安め |

### 設定の楽さ重視

| プロバイダ | プラン | 月額 | 補足 |
|---|---|---|---|
| **DigitalOcean** | Basic Droplet (2vCPU/2GB) | $18 | UI 安定、ドキュメント豊富 |
| **Fly.io** | shared-cpu-2x (2vCPU/2GB) | $7 ($0.025/h) | Caddy + broker を 1 アプリで包めて Dockerfile デプロイ |

## デプロイ前チェックリスト

公開直前の最終確認:

- [ ] `c2w-net` の NAT から `127.0.0.1` が **除去されている**
- [ ] Caddy / nginx の TLS 証明書が **有効** (`curl -v https://...` で `SSL certificate verify ok`)
- [ ] 認証なしでは静的ファイルすら見えない (`curl https://...` で 401 が返る)
- [ ] `--listen-ws` が **127.0.0.1 にバインド** されている (`ss -tlnp | grep c2w-net` で `0.0.0.0` でないこと)
- [ ] systemd の `LimitNOFILE` が **65536** 以上
- [ ] `swap` が 1〜2 GB **確保済** (`free -m`)
- [ ] broker の **slot 数 (`maxSlots`) が VPS メモリに見合う** (収容力試算と一致)
- [ ] ファイアウォール (`ufw` / `firewalld`) で **443 と 22 のみ開放**
- [ ] 監視: `htop` / `vmstat` / `c2w-net.log` を確認、24 時間放置で OOM なし
- [ ] abuse 対策: 接続先 allowlist / rate limit が想定通り動く
- [ ] (公開デモなら) Cloudflare Turnstile などの bot 対策が前段にある

## 関連ドキュメント

- [multi-tenant-architecture.md](multi-tenant-architecture.md) — broker + pool 設計、c2w-net 改修パッチ詳細
- [external-api-access.md](external-api-access.md) — ブラウザ Linux から外部 API へのアクセス
