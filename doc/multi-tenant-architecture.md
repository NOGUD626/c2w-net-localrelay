# マルチテナント対応アーキテクチャ — broker + c2w-net pool

> 状態: 設計提案。本リポジトリの PoC (ローカル loopback 用) を **複数ユーザーが同時に
> ブラウザから触れる構成** に拡張する場合の青写真。実装は未着手。

## 問題: 静的ファイルはみんな開ける、c2w-net は複数接続を受けたら何が起きるか

現状の `run.sh` の構成:

```
[ブラウザ] ──ws──> [c2w-net (1 プロセス)]
```

を VPS に置いて静的ファイル (`htdocs/`) を公開すると、誰でも URL を開いて
ws://VPS:8888 にぶら下がれる。このときの挙動を 2 軸に分解する。

### 軸 1: 「捌けるか」 (技術的能力) → ⭕ 捌ける

c2w-net の WS リスナー本体 (`c2w-src/cmd/c2w-net/main.go`):

```go
http.Handle("/", websocket.Handler(func(ws *websocket.Conn) {
    ws.PayloadType = websocket.BinaryFrame
    if err := vn.AcceptQemu(context.TODO(), ws); err != nil {
        log.Printf("forwarding finished: %v\n", err)
    }
}))
http.ListenAndServe(socketAddr, nil)
```

- Go の HTTP サーバは **接続ごとに goroutine** を作る (標準動作)
- 各 WS 接続が独立した goroutine で `AcceptQemu` を呼ぶ
- 100 同時接続 = goroutine 100 個 ≒ 数 MB のメモリ
- → サーバ側プロセス自体が詰まる/落ちるリスクは低い

### 軸 2: 「捌かせて良いか」 (設計) → ❌ そのまま公開は致命的

`vn` (= VirtualNetwork) は **プロセスに 1 個だけ**。全 WS 接続が
**同じ仮想 L2 セグメント (192.168.127.0/24)** に乗る。

```
[ユーザー A] 192.168.127.5  ┐
[ユーザー B] 192.168.127.6  ├── 全員同じセグメント
[ユーザー C] 192.168.127.7  ┘
```

これが引き起こす具体的問題:

| 問題 | 何が起きる |
|---|---|
| ピアリング | A が `arp-scan` で他者を発見、`ping 192.168.127.6` で B に到達。B のコンテナで何か LISTEN していれば叩ける |
| ARP spoofing | A が B のトラフィックを横取り可能 |
| **★ ホスト localhost ダダ漏れ** | `c2w-net main.go` の NAT 設定 `192.168.127.254 → 127.0.0.1` で、任意ユーザーから VPS の `127.0.0.1` にアクセスできる (Docker daemon, Redis, 内部 API, Grafana 等) |
| オープンプロキシ化 | VPS の IP から任意 TCP/UDP に出ていく = スパム/スクレイピング/DDoS 踏み台。法的責任は運営者 |
| DoS | 大量接続でメモリ食い尽くし、1 人の大量帯域で他人を巻き込む |
| キャパシティ | Subnet が /24 で **DHCP リースは最大 250 個程度** |

## 解決策: 3 段アーキテクチャ

```
[ブラウザ]
   │ ① 静的ファイル (index.html / out.wasm / ws-delegate.js)
   │ ② wss://demo.example.com/ws  (WebSocket upgrade)
   ↓
[Caddy or nginx]   ← TLS 終端 / 認証 / 静的配信 / WS upgrade をプロキシ
   │
   ├ /            → /var/www/.../htdocs/   (静的配信)
   └ /ws          → http://127.0.0.1:18000  (WS は broker へ)
                          │
                          ↓
[broker (自前 Go 〜 300 行)]   ← 「1 接続 = 1 専用 c2w-net」を司る
   │ 接続来たら subnet/port を払い出して c2w-net を spawn
   │ ブラウザ WS ↔ spawn した c2w-net の WS を双方向 pipe
   │ 切断で c2w-net を kill (subnet/port を返却)
   ↓
[c2w-net インスタンス群]   ← 各々別 subnet、互いに見えない
   ├ instance #1  --listen-ws=127.0.0.1:19001  --subnet=192.168.100.0/24
   ├ instance #2  --listen-ws=127.0.0.1:19002  --subnet=192.168.101.0/24
   └ ...
   ↓ ホスト OS の本物 socket() で外へ
[インターネット]
```

### 鍵となる分業

- **nginx / Caddy は「WS を broker に流す」だけの dumb proxy**
- **broker が状態を全部持つ** (誰がどの subnet を使ってるか、空きスロット管理)
- **c2w-net は 1 セッション専有モードで起動** (subnet 独立、NAT 改修済)

## レイヤー別の実装

### 1. Caddy (推奨) or nginx 設定

`Caddyfile`:

```caddy
demo.example.com {
    # 認証 (basic auth の例。実運用は forward_auth + OAuth がベター)
    basicauth {
        student1 $2a$14$...   # bcrypt
        student2 $2a$14$...
    }

    # 静的配信
    handle / {
        root * /var/www/c2w-net-localrelay/htdocs
        file_server
    }

    # WS は broker へ
    handle /ws {
        reverse_proxy 127.0.0.1:18000 {
            transport http {
                read_timeout 24h
                write_timeout 24h
            }
        }
    }
}
```

nginx でやるなら:

```nginx
server {
    listen 443 ssl http2;
    server_name demo.example.com;
    ssl_certificate     /etc/letsencrypt/live/demo.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/demo.example.com/privkey.pem;

    auth_basic "demo access";
    auth_basic_user_file /etc/nginx/.htpasswd;

    location / {
        root /var/www/c2w-net-localrelay/htdocs;
        try_files $uri $uri/ =404;
    }

    location /ws {
        proxy_pass http://127.0.0.1:18000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }
}
```

**前段は upstream を broker 1 個しか知らない**。pool 管理は全部 broker 任せ。

### 2. broker (自前 Go 〜 300 行)

役割:
1. WS upgrade を受ける
2. subnet/port を払い出す (空きスロット)
3. c2w-net を `exec.Command` で起動
4. ブラウザ WS と spawn した c2w-net の WS を双方向中継 (`io.Copy`)
5. 切断で c2w-net を kill して subnet/port を返却

雛形:

```go
package main

import (
    "fmt"
    "io"
    "log"
    "net/http"
    "os/exec"
    "sync"
    "time"

    "golang.org/x/net/websocket"
)

const (
    portBase   = 19000
    subnetBase = 100  // 192.168.100.0/24 から始める
    maxSlots   = 150  // 同時 150 セッションまで (.100〜.249)
)

type slot struct {
    port   int
    subnet string  // "192.168.100.0/24"
}

type pool struct {
    mu    sync.Mutex
    free  []slot
    inUse map[int]*exec.Cmd
}

func newPool() *pool {
    p := &pool{inUse: make(map[int]*exec.Cmd)}
    for i := 0; i < maxSlots; i++ {
        p.free = append(p.free, slot{
            port:   portBase + i,
            subnet: fmt.Sprintf("192.168.%d.0/24", subnetBase+i),
        })
    }
    return p
}

func (p *pool) acquire() (*slot, error) {
    p.mu.Lock()
    defer p.mu.Unlock()
    if len(p.free) == 0 {
        return nil, fmt.Errorf("pool exhausted")
    }
    s := p.free[len(p.free)-1]
    p.free = p.free[:len(p.free)-1]
    return &s, nil
}

func (p *pool) release(s *slot) {
    p.mu.Lock()
    defer p.mu.Unlock()
    if cmd, ok := p.inUse[s.port]; ok {
        cmd.Process.Kill()
        delete(p.inUse, s.port)
    }
    p.free = append(p.free, *s)
}

func (p *pool) spawn(s *slot) error {
    cmd := exec.Command("/opt/c2w-net/bin/c2w-net",
        "--listen-ws", fmt.Sprintf("127.0.0.1:%d", s.port),
        "--subnet", s.subnet,
        "--no-localhost-nat",     // ← 改修フラグ
        "--exit-on-disconnect",   // ← 改修フラグ
    )
    if err := cmd.Start(); err != nil {
        return err
    }
    p.mu.Lock()
    p.inUse[s.port] = cmd
    p.mu.Unlock()
    time.Sleep(200 * time.Millisecond) // ready 待ち (or healthcheck)
    return nil
}

func main() {
    p := newPool()

    http.Handle("/ws", websocket.Handler(func(clientWS *websocket.Conn) {
        s, err := p.acquire()
        if err != nil {
            log.Printf("pool full: %v", err)
            return
        }
        defer p.release(s)

        if err := p.spawn(s); err != nil {
            log.Printf("spawn failed: %v", err)
            return
        }

        // spawn した c2w-net に dial
        upstream, err := websocket.Dial(
            fmt.Sprintf("ws://127.0.0.1:%d/", s.port), "",
            "http://127.0.0.1/",
        )
        if err != nil {
            log.Printf("dial upstream: %v", err)
            return
        }
        defer upstream.Close()
        upstream.PayloadType = websocket.BinaryFrame

        // 双方向 pipe (どちらか EOF で両方終わる)
        done := make(chan struct{}, 2)
        go func() { io.Copy(upstream, clientWS); done <- struct{}{} }()
        go func() { io.Copy(clientWS, upstream); done <- struct{}{} }()
        <-done
    }))

    log.Printf("c2w-broker listening 127.0.0.1:18000")
    log.Fatal(http.ListenAndServe("127.0.0.1:18000", nil))
}
```

300 行どころか **150 行で骨格が組める**。

systemd で常駐:

```ini
# /etc/systemd/system/c2w-broker.service
[Unit]
Description=c2w-net broker
After=network.target

[Service]
Type=simple
User=c2w
ExecStart=/opt/c2w-net/bin/c2w-broker
Restart=on-failure
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
```

### 3. c2w-net 改修パッチ (Go 〜 50 行)

`c2w-src/cmd/c2w-net/main.go` に 3 つのフラグを追加:

```go
var (
    // 既存フラグ...
    subnet     = flag.String("subnet", "192.168.127.0/24", "virtual subnet")
    noHostNAT  = flag.Bool("no-localhost-nat", false, "remove 192.168.127.254 -> 127.0.0.1 NAT entry")
    exitOnDisc = flag.Bool("exit-on-disconnect", false, "exit after the first websocket session closes")
)

// Configuration 構築の所:
config := &gvntypes.Configuration{
    // ...
    Subnet: *subnet,  // ← ハードコード "192.168.127.0/24" から差し替え
    NAT: func() map[string]string {
        if *noHostNAT {
            return map[string]string{}  // 空 = localhost 漏洩を防ぐ
        }
        return map[string]string{
            "192.168.127.254": "127.0.0.1",
        }
    }(),
    // ...
}

// http handler の所:
http.Handle("/", websocket.Handler(func(ws *websocket.Conn) {
    ws.PayloadType = websocket.BinaryFrame
    if err := vn.AcceptQemu(context.TODO(), ws); err != nil {
        log.Printf("forwarding finished: %v", err)
    }
    if *exitOnDisc {
        os.Exit(0)  // 1 セッション分処理が終わったら自己 exit
    }
}))
```

> ⚠️ Subnet を可変にする際は、`GatewayIP = "192.168.127.1"`, `vmIP = "192.168.127.3"`,
> `DHCPStaticLeases` などのハードコードも subnet ベースで自動算出するよう書き換えが必要
> (追加で 30 行程度)。

## 1 セッションのライフサイクル

```
時刻  動作
----  ----------------------------------------------------------
00:00 ブラウザが https://demo.example.com/ にアクセス
00:00 Caddy が basicauth でチェック → OK → htdocs/index.html 返却
00:01 ブラウザが out.wasm 等を fetch (まだ WS 接続なし)
00:10 ブラウザ内 ws-delegate.js が wss://.../ws に接続
00:10 Caddy → broker:18000 へ proxy
00:10 broker.acquire() → slot{port: 19042, subnet: 192.168.142.0/24} 払い出し
00:10 broker.spawn() → c2w-net --listen-ws 127.0.0.1:19042 \
            --subnet 192.168.142.0/24 --no-localhost-nat --exit-on-disconnect
00:11 broker が ws://127.0.0.1:19042/ に dial、双方向 pipe 開始
00:11 ブラウザ内 Linux が起動、192.168.142.X が降りる (他人と分離)
30:00 ユーザーが帰る、タブ閉じる → ブラウザ WS が close
30:00 broker の io.Copy が EOF → done に飛んで return
30:00 broker.release() → c2w-net を kill、slot を free に戻す
30:00 slot 19042 / 192.168.142.0/24 が次の人に再利用される
```

## 簡易版: 静的プール + sticky session (broker なし)

「broker を書くのが面倒。教室 30 人ぴったりで運用する」なら、**動的 spawn 抜きの簡易版**で組める:

1. 起動時に c2w-net を 30 個 spawn (port 19001〜19030, subnet 192.168.100.0/24〜129.0/24)
2. nginx で `ip_hash` で振り分け (同じクライアント IP は同じ upstream に固定)
3. 接続終了してもインスタンスは生かしっぱなし、再利用

```nginx
upstream c2w_pool {
    ip_hash;  # 同じクライアント IP は同じ upstream に固定
    server 127.0.0.1:19001;
    server 127.0.0.1:19002;
    # ...30 個
}

location /ws {
    proxy_pass http://c2w_pool;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_read_timeout 86400s;
}
```

**問題点**:
- `ip_hash` は IP 単位なので、同じ NAT 内の 2 人が同じ upstream に当たる可能性あり (= L2 共有が局所的に再発)
- 「使われてない」インスタンスを選ぶ機構がない (= 偏りが起きる)
- A さんが帰った後の DHCP リース・接続テーブルが残る (再接続したらリース番号変わるだけだが、ARP テーブル等は数分残る)

**それでも教室レベル (30 人、互いに知り合い) なら許容範囲**。実装が圧倒的に楽。

## 労力見積もり

| パターン | 実装規模 | 期間 |
|---|---|---|
| **静的プール + nginx ip_hash** (簡易) | 設定ファイルだけ。c2w-net は無改修 OR 軽改修 (subnet) | 半日 |
| **broker + 動的 spawn + c2w-net 改修** (本格) | broker 150〜300 行、c2w-net パッチ 50〜100 行、Caddy 設定、systemd | 2〜3 日 |
| **完全分離 (docker per session)** | 各セッションで Docker 起動。さらに重い | 1 週間 |

## 推奨判断

| 規模 | 構成 | 補足 |
|---|---|---|
| 5〜30 人、内輪、教室 | **簡易版 (ip_hash プール)** | broker なしで足りる。同じ NAT 内の重なりは「自己責任」で許容 |
| 30〜100 人、招待制、社外 | **broker パターン** | 1 接続 1 専用 c2w-net で完全分離 |
| 公開 (匿名アクセス可) | broker + abuse 対策一式 | rate limit、接続先 allowlist、Cloudflare WAF |
| 大規模 / マルチリージョン | broker per region + 認証基盤 | スコープ外 |

## 関連ドキュメント

- [vps-deployment.md](vps-deployment.md) — VPS スペック見積もり、必須対策チェックリスト
- [external-api-access.md](external-api-access.md) — ブラウザ Linux から API (Notion / GitHub / OpenAI 等) を叩く
