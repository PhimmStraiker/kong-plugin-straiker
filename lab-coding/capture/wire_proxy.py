#!/usr/bin/env python3
"""Record-and-forward wire proxy for Claude Code traffic.

Point Claude Code at this with ANTHROPIC_BASE_URL=http://127.0.0.1:<port>. It
does a byte-exact raw passthrough to the real Anthropic API over TLS, teeing
both the request body and the (streaming SSE) response to a JSONL capture file.
Streaming is preserved (raw socket relay, Connection: close), so Claude Code
behaves normally while every /v1/messages request+response is recorded.

Records one JSON object per exchange to --out:
  {seq, ts_start, ts_first_byte, ts_end, method, path,
   req_headers (auth redacted), req_body (parsed if JSON),
   resp_status, resp_headers, resp_sse (parsed events) | resp_body}

Usage:
  python wire_proxy.py --port 8788 --upstream api.anthropic.com --out cap.jsonl
"""
import argparse, json, socket, ssl, sys, threading, time

REDACT = {"x-api-key", "authorization", "anthropic-auth-token"}


def _read_headers(sock_file):
    """Read request line + headers up to blank line. Returns (request_line, [(k,v)], raw_bytes)."""
    lines = []
    raw = bytearray()
    while True:
        line = sock_file.readline()
        if not line:
            break
        raw += line
        if line in (b"\r\n", b"\n"):
            break
        lines.append(line)
    if not lines:
        return None, [], bytes(raw)
    request_line = lines[0].decode("latin1").rstrip("\r\n")
    headers = []
    for ln in lines[1:]:
        s = ln.decode("latin1").rstrip("\r\n")
        if ":" in s:
            k, v = s.split(":", 1)
            headers.append((k.strip(), v.strip()))
    return request_line, headers, bytes(raw)


def _hval(headers, name):
    name = name.lower()
    for k, v in headers:
        if k.lower() == name:
            return v
    return None


def _redact(headers):
    out = {}
    for k, v in headers:
        out[k] = "<redacted>" if k.lower() in REDACT else v
    return out


def _parse_sse(raw: bytes):
    """Parse an Anthropic SSE stream into a list of {event, data} (data JSON-decoded when possible)."""
    events = []
    text = raw.decode("utf-8", "replace")
    cur_event, cur_data = None, []
    for line in text.split("\n"):
        line = line.rstrip("\r")
        if line == "":
            if cur_event or cur_data:
                data_str = "\n".join(cur_data)
                try:
                    data_val = json.loads(data_str)
                except Exception:
                    data_val = data_str
                events.append({"event": cur_event, "data": data_val})
            cur_event, cur_data = None, []
            continue
        if line.startswith("event:"):
            cur_event = line[6:].strip()
        elif line.startswith("data:"):
            cur_data.append(line[5:].strip())
    return events


class Proxy:
    def __init__(self, upstream, out_path):
        self.upstream = upstream
        self.out_path = out_path
        self.seq = 0
        self.lock = threading.Lock()

    def record(self, rec):
        with self.lock:
            with open(self.out_path, "a") as f:
                f.write(json.dumps(rec) + "\n")

    def handle(self, client):
        cf = client.makefile("rb")
        request_line, headers, _ = _read_headers(cf)
        if not request_line:
            client.close()
            return
        try:
            method, path, _ = request_line.split(" ", 2)
        except ValueError:
            client.close()
            return

        # read request body
        body = b""
        clen = _hval(headers, "content-length")
        if clen:
            try:
                body = cf.read(int(clen))
            except Exception:
                body = b""

        ts_start = time.time()

        # rebuild request headers for upstream: force real Host, identity encoding, close
        new_headers = []
        for k, v in headers:
            lk = k.lower()
            if lk in ("host", "accept-encoding", "connection", "content-length"):
                continue
            new_headers.append((k, v))
        new_headers.append(("Host", self.upstream))
        new_headers.append(("Accept-Encoding", "identity"))
        new_headers.append(("Connection", "close"))
        new_headers.append(("Content-Length", str(len(body))))

        req_bytes = (f"{method} {path} HTTP/1.1\r\n").encode("latin1")
        for k, v in new_headers:
            req_bytes += f"{k}: {v}\r\n".encode("latin1")
        req_bytes += b"\r\n" + body

        # connect upstream over TLS
        ctx = ssl.create_default_context()
        raw = socket.create_connection((self.upstream, 443), timeout=120)
        up = ctx.wrap_socket(raw, server_hostname=self.upstream)
        up.sendall(req_bytes)

        # read upstream response fully, teeing to client
        resp = bytearray()
        ts_first = None
        up.settimeout(120)
        try:
            while True:
                chunk = up.recv(65536)
                if not chunk:
                    break
                if ts_first is None:
                    ts_first = time.time()
                resp += chunk
                try:
                    client.sendall(chunk)
                except Exception:
                    pass
        except Exception:
            pass
        ts_end = time.time()
        try:
            up.close()
        except Exception:
            pass
        try:
            client.shutdown(socket.SHUT_WR)
        except Exception:
            pass
        client.close()

        # split response head/body
        sep = resp.find(b"\r\n\r\n")
        if sep == -1:
            resp_status, resp_headers, resp_body = None, [], bytes(resp)
        else:
            head = resp[:sep].decode("latin1")
            resp_body = bytes(resp[sep + 4:])
            hlines = head.split("\r\n")
            resp_status = hlines[0]
            resp_headers = []
            for ln in hlines[1:]:
                if ":" in ln:
                    k, v = ln.split(":", 1)
                    resp_headers.append((k.strip(), v.strip()))

        # de-chunk if needed for parsing (Anthropic streams chunked)
        body_for_parse = resp_body
        te = _hval(resp_headers, "transfer-encoding")
        if te and "chunked" in te.lower():
            body_for_parse = _dechunk(resp_body)

        ctype = _hval(resp_headers, "content-type") or ""
        rec = {
            "seq": self._next(),
            "ts_start": ts_start,
            "ts_first_byte": ts_first,
            "ts_end": ts_end,
            "ttfb_ms": round((ts_first - ts_start) * 1000, 1) if ts_first else None,
            "total_ms": round((ts_end - ts_start) * 1000, 1),
            "method": method,
            "path": path,
            "req_headers": _redact(headers),
            "req_body": _try_json(body),
            "req_bytes": len(body),
            "resp_status": resp_status,
            "resp_headers": dict(resp_headers),
            "resp_bytes": len(body_for_parse),
        }
        if "text/event-stream" in ctype:
            rec["resp_sse"] = _parse_sse(body_for_parse)
        else:
            rec["resp_body"] = _try_json(body_for_parse)
        self.record(rec)

    def _next(self):
        with self.lock:
            self.seq += 1
            return self.seq


def _dechunk(data: bytes) -> bytes:
    out = bytearray()
    i = 0
    n = len(data)
    while i < n:
        j = data.find(b"\r\n", i)
        if j == -1:
            break
        try:
            size = int(data[i:j].split(b";")[0], 16)
        except ValueError:
            break
        i = j + 2
        if size == 0:
            break
        out += data[i:i + size]
        i += size + 2
    return bytes(out)


def _try_json(b: bytes):
    try:
        return json.loads(b.decode("utf-8"))
    except Exception:
        return b.decode("utf-8", "replace")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8788)
    ap.add_argument("--upstream", default="api.anthropic.com")
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    proxy = Proxy(args.upstream, args.out)
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", args.port))
    srv.listen(64)
    print(f"wire_proxy: 127.0.0.1:{args.port} -> {args.upstream} (out={args.out})", flush=True)
    while True:
        try:
            client, _ = srv.accept()
        except KeyboardInterrupt:
            break
        threading.Thread(target=proxy.handle, args=(client,), daemon=True).start()


if __name__ == "__main__":
    main()
