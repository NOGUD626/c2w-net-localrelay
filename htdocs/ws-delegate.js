function delegate(worker, workerImageName, address) {
    var shared = new SharedArrayBuffer(8 + 4096);
    var streamCtrl = new Int32Array(shared, 0, 1);
    var streamStatus = new Int32Array(shared, 4, 1);
    var streamLen = new Int32Array(shared, 8, 1);
    var streamData = new Uint8Array(shared, 12);
    worker.postMessage({type: "init", buf: shared, imagename: workerImageName});

    var opts = 'binary';
    // worker から見た状態。TinyEMU は起動時に一度しか accept してこないため、
    // 一度 opened/accepted になったら「WS が切れても」この 2 つは true のまま維持し、
    // 実際の繋ぎ直しは JS 層で透過的に行う (worker は切断に気付かない)。
    var opened = false;     // 一度でも WebSocket を開けたか
    var accepted = false;   // worker が accept 済みか
    var wsReady = false;    // 現在の WebSocket が送信可能か
    var connecting = false; // 接続/再接続が進行中か
    var wsconn;
    var connbuf = new Uint8Array(0);

    // 再接続バックオフ (ms)。成功で最小値にリセットする。
    var reconnectDelay = 500;
    var RECONNECT_MIN = 500, RECONNECT_MAX = 5000;

    // WS ダウン中の送信フレームを一時退避する (上限つき。あふれたら古いものから捨てる)。
    // ARP/DNS 等の再送が再接続直後に届くよう、破棄ではなくキューする。
    var sendQueue = [];
    var SENDQUEUE_MAX = 256;

    function flushQueue() {
        while (sendQueue.length > 0 && wsconn && wsconn.readyState === WebSocket.OPEN) {
            wsconn.send(sendQueue.shift());
        }
    }

    function connect() {
        if (connecting) return;
        if (wsconn && (wsconn.readyState === WebSocket.OPEN || wsconn.readyState === WebSocket.CONNECTING)) return;
        connecting = true;
        var c = new WebSocket(address, opts);
        c.binaryType = 'arraybuffer';
        c.onmessage = function(event) {
            var buf2 = new Uint8Array(connbuf.length + event.data.byteLength);
            buf2.set(connbuf, 0);
            buf2.set(new Uint8Array(event.data), connbuf.length);
            connbuf = buf2;
        };
        c.onopen = function() {
            opened = true;
            wsReady = true;
            connecting = false;
            reconnectDelay = RECONNECT_MIN; // 接続成功でバックオフをリセット
            flushQueue();
        };
        c.onclose = function(event) {
            console.log("websocket closed " + event.code + " " + event.reason + " " + event.wasClean);
            wsReady = false;
            connecting = false;
            scheduleReconnect();
        };
        c.onerror = function() {
            console.log("websocket error");
            wsReady = false;
            // onerror の後に onclose も呼ばれるので、再接続はそちらに任せる
        };
        wsconn = c;
    }

    // 透過的再接続: 一度でも accept 済みなら worker は再 accept してこないので、
    // JS 側でバックオフしつつ繋ぎ直す。ゲストの eth0/IP/ルートはそのままなので、
    // 再接続後は ARP 再学習 + keepalive トラフィックで通信が自動復旧する。
    function scheduleReconnect() {
        if (!accepted && !opened) return; // まだ一度も開けていない初回失敗時は何もしない
        setTimeout(connect, reconnectDelay);
        reconnectDelay = Math.min(reconnectDelay * 2, RECONNECT_MAX);
    }

    return function(msg) {
        const req_ = msg.data;
        if (typeof req_ == "object" && req_.type) {
            switch (req_.type) {
            case "accept":
                if (opened) {
                    streamData[0] = 1; // opened
                    accepted = true;
                } else {
                    streamData[0] = 0; // not opened
                    connect();
                }
                streamStatus[0] = 0;
                break;
            case "send":
                if (!accepted) {
                    console.log("ERROR: cannot send to unaccepted websocket");
                    streamStatus[0] = -1;
                    break;
                }
                if (wsReady && wsconn && wsconn.readyState === WebSocket.OPEN) {
                    flushQueue();
                    wsconn.send(req_.buf);
                } else {
                    // 再接続中: フレームを退避して再開後に送る (worker にはエラーを返さない)
                    if (sendQueue.length >= SENDQUEUE_MAX) sendQueue.shift();
                    sendQueue.push(req_.buf);
                }
                streamStatus[0] = 0;
                break;
            case "recv":
                if (!accepted) {
                    console.log("ERROR: cannot receive from unaccepted websocket");
                    streamStatus[0] = -1;
                    break;
                }
                var length = req_.len;
                if (length > streamData.length)
                    length = streamData.length;
                if (length > connbuf.length)
                    length = connbuf.length
                var buf = connbuf.slice(0, length);
                var remain = connbuf.slice(length, connbuf.length);
                connbuf = remain;
                streamLen[0] = buf.length;
                streamData.set(buf, 0);
                streamStatus[0] = 0;
                break;
            case "recv-is-readable":
                if (!accepted) {
                    console.log("ERROR: cannot poll unaccepted websocket");
                    streamStatus[0] = -1;
                    break;
                }
                if (connbuf.length > 0) {
                    streamData[0] = 1; // ready for reading
                } else {
                    streamData[0] = 0; // timeout
                }
                streamStatus[0] = 0;
                break;
            default:
                console.log("unknown request: " +  req_.type)
                return;
            }
            Atomics.store(streamCtrl, 0, 1);
            Atomics.notify(streamCtrl, 0);
        }
    }
}
