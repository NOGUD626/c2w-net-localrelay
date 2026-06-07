# 逆方向 (inbound) 通信: `-p host:guest` の仕組み

> 状態: 仕組みの整理 + フラグ確認済。`c2w-net --help` に `-p`（ホスト→ゲストの
> ポートフォワード）が存在することは実機で確認済だが、本リポジトリの公開構成では
> 未使用。実際に inbound を通す運用検証は未実施。

## 結論を先に

| やりたいこと | 可否 | 補足 |
|---|---|---|
| wasm 内 Linux から外へ出る (outbound) | ⭕ | NAT で自動。設定不要。[external-api-access.md](external-api-access.md) 参照 |
| ホスト → wasm 内 Linux のポートへ入る (inbound) | △ | `c2w-net -p host:guest` で原理的には可能。ただし制約多数 (後述) |
| インターネット → wasm 内 Linux を常時公開 | ❌ | タブ寿命・単一スタック・Tunnel が TCP 非対応で非現実的 |

`-p` の help 表記:

```
-p value   map port between host and guest (host:guest). -mac must be set correctly.
```

## なぜ outbound は自動で、inbound は明示登録が要るのか

通信を終端しているのは **ホストでもゲストでもなく、その間に挟まった
`gvisor-tap-vsock` (c2w-net 内の Go 製ユーザー空間 TCP/IP スタック)** である。
これは「ソフトで書かれた仮想ルータ / NAT」であって、Linux カーネルは関与しない。

```
[外 / ホスト] ── ホスト Linux カーネル (本物の socket)       ← 本物の Linux
        │
[gvisor-tap-vsock] ← c2w-net 内のユーザー空間 TCP/IP + NAT (Go)  ← 仮想ルータ。カーネル非関与
        │ L2 イーサフレームを WebSocket で中継
[ブラウザ] ── [TinyEMU (wasm)] ── ゲスト Linux の eth0          ← “別の” Linux カーネル
```

- **outbound (wasm → 外)**: ゲスト (192.168.127.x) → ゲートウェイ (192.168.127.1) で
  NAT/masquerade → ホストの本物 socket() で外へ。戻りパケットは NAT state で自然に返る。
  → **だから設定なしで通る。**
- **inbound (外 → wasm)**: 外から見ると 192.168.127.x はプライベートで直接届かない。
  仮想ルータに「ホストの :N に来た接続を、内部の guest IP:port へ橋渡しせよ」という
  **ポートフォワード (expose) を登録**する必要がある。これが `-p` の役目。

## `-p` は Linux の仕組みではない (Docker の `-p` との違い)

記法は `docker run -p` から借りているが、レイヤーが全く違う。

| | Docker の `-p` | c2w-net の `-p` |
|---|---|---|
| 転送の実装 | Linux カーネルの **iptables / netfilter (DNAT)** | `gvisor-tap-vsock` が **アプリ内ユーザー空間**で橋渡し |
| カーネル関与 | あり (パケットをカーネルが書き換え) | なし (netstack = gVisor TCP/IP の Go 移植上の処理) |
| イメージ | OS のルーターに穴を開ける | アプリ内蔵の小さな仮想ルータの設定をいじる |

`-mac must be set correctly` が要求されるのもこのため。ユーザー空間スタックは
「どの MAC のゲストにフレームを届けるか」を自分で判断するので、転送先を MAC で
明示する必要がある。

## 現構成にそのまま入れるときつい理由

現在の起動はこれだけで、`-p` は付いていない:

```
ExecStart=/home/noguchi/c2w-deploy/c2w-net --listen-ws 127.0.0.1:8888
```

しかも本リポジトリの公開構成は **1 つの c2w-net に全ブラウザが同じ subnet で
ぶら下がる**状態 ([multi-tenant-architecture.md](multi-tenant-architecture.md) 参照、
利用者同士が `arp-scan` で見え合うレベル)。ここに `-p` を足すと:

1. **inbound 先が一意に決まらない (最大の問題)**
   `-p host:guest` は「ホスト :N → 特定の guest IP/MAC」への 1 対 1 転送。
   全ユーザーが 1 スタック共有 + `-mac` デフォルト (`02:00:00:00:00:01`) のままだと、
   「:N に来た接続を誰のタブに届けるか」が決められない。
2. **タブ依存で寿命が短い**
   転送先 (wasm 内サーバ) は、そのタブの WebSocket が生きている間しか存在しない。
   ホスト側 :N は LISTEN し続けるが繋がる相手が居ない時間は死にポート。
   再接続で DHCP リースが変われば転送先もズレる。
3. **公開経路 (Cloudflare Tunnel) が TCP 向きではない**
   外部公開は Cloudflare Tunnel (HTTP 終端) + nginx の Basic 認証。`-p` で開けた
   生 TCP ポートはこの HTTP 経路に乗らず、外から叩かせるには cloudflared の
   TCP ルーティングか別ホスト名が要る。さらにその経路は **Basic 認証を素通り**する。
4. **セキュリティ**
   全ユーザー共有スタックに外から穴を開ける = 他人のサンドボックス内サービスに
   到達しうる方向に広げることになる。

一方で **負荷そのものは無視できる**。転送は gvisor-tap-vsock のユーザー空間処理で、
メモリは goroutine 数 MB 程度 (multi-tenant-architecture.md の「100 接続 ≒ 数 MB」)。
`-p` を足しても CPU/メモリは事実上増えない。

## 用途別の評価

| 用途 | 評価 |
|---|---|
| 1 人・ホスト内から (非公開)・1 タブ | ⭕ 余裕。`-p host:guest` + `-mac` を合わせるだけで動く |
| 今のマルチユーザー公開デモにそのまま追加 | ❌ きつい。負荷ではなく「宛先が一意に決まらない / タブ寿命 / Tunnel が TCP 非対応 / 認証素通り」で破綻 |

inbound を実用にするなら、[multi-tenant-architecture.md](multi-tenant-architecture.md)
の broker 案 (ユーザーごとに別 subnet・別 c2w-net インスタンス) とセットで、
`-p` をそのインスタンス専用に張る形にする必要がある。
