#!/usr/bin/env python3
"""Turn a raw-capture session file (what Kong saw) into a readable export.

Input:  konnect/out/capture/<session>.jsonl  (request/response records, in order)
Output: konnect/out/export/<session>/
          summary.md              human-readable: prompt -> every model call
          call_NN_request.json    the literal raw request body Kong received
          call_NN_response.(sse|json|eventstream.txt)  the literal raw response
          session.jsonl           copy of the raw capture

Usage: python3 export_capture.py <session_id | path-to-jsonl>
"""
import base64, json, os, sys


def parse_sse(text):
    events = []
    cur_e, cur_d = None, []
    for line in text.split("\n"):
        line = line.rstrip("\r")
        if line == "":
            if cur_e or cur_d:
                try: data = json.loads("\n".join(cur_d))
                except Exception: data = "\n".join(cur_d)
                events.append({"event": cur_e, "data": data})
            cur_e, cur_d = None, []
        elif line.startswith("event:"): cur_e = line[6:].strip()
        elif line.startswith("data:"): cur_d.append(line[5:].strip())
    return events


def decode_eventstream(raw: bytes):
    events, i, n = [], 0, len(raw)
    while i + 12 <= n:
        total = int.from_bytes(raw[i:i+4], "big"); hlen = int.from_bytes(raw[i+4:i+8], "big")
        if total < 16 or i + total > n: break
        payload = raw[i+12+hlen:i+total-4]
        try:
            outer = json.loads(payload)
            if "bytes" in outer:
                events.append(json.loads(base64.b64decode(outer["bytes"])))
        except Exception: pass
        i += total
    return events


def assemble(events):
    """Anthropic message-stream events -> assistant text + tool_uses."""
    blocks = {}; stop = None
    for ev in events:
        d = ev.get("data") if "data" in ev else ev
        if not isinstance(d, dict): continue
        t = d.get("type")
        if t == "content_block_start":
            cb = d.get("content_block", {})
            blocks[d.get("index")] = {"type": cb.get("type"), "name": cb.get("name"), "text": cb.get("text", ""), "_j": ""}
        elif t == "content_block_delta":
            b = blocks.get(d.get("index")); dl = d.get("delta", {})
            if b:
                if dl.get("type") == "text_delta": b["text"] += dl.get("text", "")
                elif dl.get("type") == "input_json_delta": b["_j"] += dl.get("partial_json", "")
        elif t == "message_delta":
            stop = d.get("delta", {}).get("stop_reason", stop)
    text, tools = "", []
    for i in sorted(blocks):
        b = blocks[i]
        if b["type"] == "text": text += b["text"]
        elif b["type"] == "tool_use":
            try: inp = json.loads(b["_j"]) if b["_j"] else {}
            except Exception: inp = {}
            tools.append({"name": b["name"], "input": inp})
    return text, tools, stop


def last_user(msgs):
    for m in reversed(msgs):
        if m.get("role") == "user":
            c = m.get("content")
            if isinstance(c, str): return ("text", c)
            if isinstance(c, list):
                kinds = [b.get("type") for b in c if isinstance(b, dict)]
                texts = [b.get("text") for b in c if isinstance(b, dict) and b.get("type") == "text"]
                trs = [b for b in c if isinstance(b, dict) and b.get("type") == "tool_result"]
                if trs: return ("tool_result", trs[-1])
                return ("text", texts[-1] if texts else "")
    return ("none", "")


def main():
    arg = sys.argv[1]
    here = os.path.dirname(os.path.abspath(__file__))
    path = arg if os.path.exists(arg) else os.path.join(here, "out", "capture", arg + ".jsonl")
    sid = os.path.basename(path).replace(".jsonl", "")
    rows = [json.loads(l) for l in open(path)]

    outdir = os.path.join(here, "out", "export", sid)
    os.makedirs(outdir, exist_ok=True)
    with open(os.path.join(outdir, "session.jsonl"), "w") as f:
        for r in rows: f.write(json.dumps(r) + "\n")

    md = [f"# Raw Kong capture — session `{sid}`\n",
          "Every model call Kong saw for one Claude Code prompt, in order. "
          "This is the literal wire (request Kong received + response Kong returned).\n"]
    # pair request<->response by Kong's request_id (rid), which is identical for
    # a request's access and response phases; robust to async title-gen ordering.
    # Fall back to nearest-unpaired if rid is missing (older captures).
    calls, by_rid = [], {}
    for r in rows:
        if r["phase"] == "request":
            c = {"req": r, "resp": None}
            calls.append(c)
            if r.get("rid"):
                by_rid[r["rid"]] = c
        else:
            c = by_rid.get(r.get("rid"))
            if c is None:
                for cc in reversed(calls):
                    if cc["resp"] is None:
                        c = cc; break
            if c is not None:
                c["resp"] = r
    # keep request order
    calls.sort(key=lambda c: c["req"]["ts"])

    # find the real user prompt (first main turn's last user text)
    user_prompt = None
    for c in calls:
        b = json.loads(c["req"]["body"])
        if b.get("tools"):
            k, v = last_user(b.get("messages", []))
            if k == "text" and v and not v.startswith("<system-reminder>"):
                user_prompt = v; break
    md.append(f"**User prompt:** `{(user_prompt or '?')[:200]}`\n")
    md.append(f"**Model calls Kong saw:** {len(calls)}\n\n---\n")

    for i, c in enumerate(calls, 1):
        req = c["req"]; resp = c["resp"]
        b = json.loads(req["body"])
        model = b.get("model") or "(bedrock: model in path)"
        tools = [t.get("name") for t in b.get("tools", [])]
        sysb = len(json.dumps(b.get("system", ""))) if b.get("system") else 0
        k, v = last_user(b.get("messages", []))
        kind = "utility/title-gen" if not b.get("tools") else "main turn"
        md.append(f"## Call {i} — {kind}\n")
        md.append(f"- **request:** `{req['method']} {req['path']}` host `{req.get('host')}` — **{req['body_bytes']:,} bytes**")
        md.append(f"- model `{model}`, system prompt **{sysb:,} B**, **{len(tools)} tools** {tools[:6]}{'…' if len(tools) > 6 else ''}")
        md.append(f"- messages: {len(b.get('messages', []))}; last user block: **{k}**"
                  + (f" — `{str(v)[:80]}`" if k == 'text' else ""))
        # raw request file
        rq = os.path.join(outdir, f"call_{i:02d}_request.json")
        open(rq, "w").write(req["body"])
        md.append(f"- raw request: `call_{i:02d}_request.json`")
        # response
        if resp:
            ct = resp.get("content_type", "")
            body = resp["body"]
            if resp.get("encoding") == "base64":
                raw = base64.b64decode(body)
                evs = decode_eventstream(raw)
                text, tu, stop = assemble(evs)
                ext = "eventstream.b64"; open(os.path.join(outdir, f"call_{i:02d}_response.{ext}"), "w").write(body)
            elif "event-stream" in ct:
                evs = parse_sse(body); text, tu, stop = assemble(evs)
                ext = "sse"; open(os.path.join(outdir, f"call_{i:02d}_response.{ext}"), "w").write(body)
            else:
                try:
                    j = json.loads(body); text = "".join(x.get("text", "") for x in j.get("content", []) if x.get("type") == "text")
                    tu = [{"name": x.get("name"), "input": x.get("input")} for x in j.get("content", []) if x.get("type") == "tool_use"]
                    stop = j.get("stop_reason")
                except Exception: text, tu, stop = body[:200], [], None
                ext = "json"; open(os.path.join(outdir, f"call_{i:02d}_response.{ext}"), "w").write(body)
            md.append(f"- **response:** {resp['status']} `{ct}` — **{resp['body_bytes']:,} bytes**, stop=`{stop}`")
            if tu: md.append(f"  - tool_use: " + ", ".join(f"`{t['name']}({json.dumps(t['input'])[:60]})`" for t in tu))
            if text.strip(): md.append(f"  - assistant text: `{text.strip()[:160]}`")
            md.append(f"- raw response: `call_{i:02d}_response.{ext}`")
        md.append("")

    open(os.path.join(outdir, "summary.md"), "w").write("\n".join(md))
    print(f"exported {len(calls)} model calls -> {outdir}")
    print(f"  summary: {os.path.join(outdir, 'summary.md')}")
    print("\n".join(md[:40]))


if __name__ == "__main__":
    main()
