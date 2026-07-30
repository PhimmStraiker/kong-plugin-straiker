#!/usr/bin/env python3
"""Summarize the anatomy of a captured wire.jsonl (Claude Code /v1/messages traffic)."""
import json, sys


def block_types(content):
    if isinstance(content, str):
        return ["<string>"]
    if isinstance(content, list):
        return [b.get("type", "?") if isinstance(b, dict) else type(b).__name__ for b in content]
    return [type(content).__name__]


def summarize(path):
    rows = [json.loads(l) for l in open(path)]
    print(f"\n===== {path} :: {len(rows)} wire calls =====")
    for r in rows:
        b = r.get("req_body")
        if not isinstance(b, dict):
            print(f"\n#{r['seq']}  (non-JSON req, {r['req_bytes']}B, status {r.get('resp_status')})")
            continue
        model = b.get("model")
        sys_field = b.get("system")
        sys_len = len(json.dumps(sys_field)) if sys_field is not None else 0
        tools = b.get("tools") or []
        tool_names = [t.get("name") for t in tools if isinstance(t, dict)]
        md = b.get("metadata") or {}
        msgs = b.get("messages") or []
        stream = b.get("stream")
        print(f"\n#{r['seq']}  model={model} stream={stream} req={r['req_bytes']}B resp={r['resp_bytes']}B ttfb={r['ttfb_ms']}ms")
        print(f"   metadata.user_id = {md.get('user_id')}")
        print(f"   system: {sys_len}B  tools: {len(tools)} {tool_names[:8]}{'...' if len(tool_names)>8 else ''}")
        for i, m in enumerate(msgs):
            role = m.get("role")
            bts = block_types(m.get("content"))
            # detail tool_use / tool_result
            extra = []
            if isinstance(m.get("content"), list):
                for blk in m["content"]:
                    if not isinstance(blk, dict):
                        continue
                    if blk.get("type") == "tool_use":
                        extra.append(f"tool_use[{blk.get('name')} id={blk.get('id','')[:12]} input={json.dumps(blk.get('input'))[:80]}]")
                    elif blk.get("type") == "tool_result":
                        c = blk.get("content")
                        cs = c if isinstance(c, str) else json.dumps(c)
                        extra.append(f"tool_result[for={blk.get('tool_use_id','')[:12]} err={blk.get('is_error')} {cs[:80]!r}]")
                    elif blk.get("type") == "text":
                        extra.append(f"text[{blk.get('text','')[:60]!r}]")
            print(f"     msg[{i}] {role}: {bts}")
            for e in extra:
                print(f"          {e}")
        # response SSE
        if "resp_sse" in r:
            evs = r["resp_sse"]
            etypes = [e.get("event") for e in evs]
            # collapse consecutive dupes
            collapsed = []
            for e in etypes:
                if not collapsed or collapsed[-1][0] != e:
                    collapsed.append([e, 1])
                else:
                    collapsed[-1][1] += 1
            print(f"   resp SSE events: " + ", ".join(f"{e}x{n}" if n > 1 else f"{e}" for e, n in collapsed))
            # extract assistant tool_use / text from SSE
            cur = {}
            for e in evs:
                d = e.get("data")
                if not isinstance(d, dict):
                    continue
                if e.get("event") == "content_block_start":
                    cb = d.get("content_block", {})
                    if cb.get("type") == "tool_use":
                        print(f"      >> response tool_use: name={cb.get('name')} id={cb.get('id','')[:12]}")
                    elif cb.get("type") == "text":
                        pass
                if e.get("event") == "message_delta":
                    dd = d.get("delta", {})
                    if dd.get("stop_reason"):
                        print(f"      >> stop_reason={dd.get('stop_reason')}")


if __name__ == "__main__":
    for p in sys.argv[1:]:
        summarize(p)
