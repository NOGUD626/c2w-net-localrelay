// container2wasm デモ用の静的配信サーバ
//
// SharedArrayBuffer (xterm-pty の同期 stdin/stdout に必須) を有効化するため、
// レスポンスに Cross-Origin Isolation (COOP/COEP) ヘッダを必ず付与する。
// これは公式デモの xterm-pty.conf (Apache 設定) と同じ役割を Node で果たすもの。
//
// 使い方: node serve.mjs   (PORT / HOST は環境変数で上書き可)

import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { join, normalize, extname, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));

// --- 設定値はすべて定数化 (マジックナンバー禁止) ---
const PORT = Number(process.env.PORT ?? 8080);
const HOST = process.env.HOST ?? "127.0.0.1";
const DOC_ROOT = join(SCRIPT_DIR, "htdocs");
const INDEX_FILE = "/index.html";

// 拡張子 → Content-Type 対応表
const MIME_TYPES = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".mjs": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".wasm": "application/wasm",
  ".map": "application/json; charset=utf-8",
};
const DEFAULT_MIME = "application/octet-stream";

// Cross-Origin Isolation 用ヘッダ (SharedArrayBuffer に必須)
const ISOLATION_HEADERS = {
  "Cross-Origin-Opener-Policy": "same-origin",
  "Cross-Origin-Embedder-Policy": "require-corp",
  "Cross-Origin-Resource-Policy": "same-origin",
};

/** リクエストパスを DOC_ROOT 配下の安全な絶対パスへ解決する。範囲外なら null を返す。 */
function resolveSafePath(urlPath) {
  const rel = urlPath === "/" ? INDEX_FILE : urlPath;
  const abs = normalize(join(DOC_ROOT, rel));
  // ディレクトリトラバーサル対策: DOC_ROOT の外を指していたら拒否
  if (abs !== DOC_ROOT && !abs.startsWith(DOC_ROOT + "/")) {
    return null;
  }
  return abs;
}

const server = createServer(async (req, res) => {
  // GET / HEAD 以外は早期 return (guard clause)
  if (req.method !== "GET" && req.method !== "HEAD") {
    res.writeHead(405, ISOLATION_HEADERS).end("Method Not Allowed");
    return;
  }

  const urlPath = decodeURIComponent(
    new URL(req.url, `http://${req.headers.host}`).pathname,
  );
  const filePath = resolveSafePath(urlPath);
  if (filePath === null) {
    res.writeHead(403, ISOLATION_HEADERS).end("Forbidden");
    return;
  }

  let body;
  try {
    body = await readFile(filePath);
  } catch {
    res.writeHead(404, ISOLATION_HEADERS).end("Not Found");
    return;
  }

  const mime = MIME_TYPES[extname(filePath)] ?? DEFAULT_MIME;
  res.writeHead(200, {
    "Content-Type": mime,
    "Content-Length": body.length,
    ...ISOLATION_HEADERS,
  });
  res.end(req.method === "HEAD" ? undefined : body);
});

server.listen(PORT, HOST, () => {
  console.log(`[container2wasm-demo] 配信開始: http://${HOST}:${PORT}/`);
  console.log(`[container2wasm-demo] DOC_ROOT = ${DOC_ROOT}`);
  console.log("[container2wasm-demo] COOP/COEP 有効 (SharedArrayBuffer 対応)");
});
