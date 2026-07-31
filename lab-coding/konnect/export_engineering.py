#!/usr/bin/env python3
"""Export the engineering mapping FROM KONG's logs.

Reads Kong's file-log (kong.jsonl — Kong's native log serializer, enriched by the
straiker-coding plugin) and produces, for real Claude Code traffic, a documented
mapping per model call:

  User Prompt  ->  Raw Kong request  ->  Straiker plugin synthesis  ->
  exact payload sent to Straiker (and how)  ->  Straiker verdict

Outputs to konnect/out/engineering/:
  kong_straiker_mapping.md      documented, human-readable, grouped by session
  mapping.jsonl                 one structured record per model call (for tooling)
  kong.jsonl                    copy of Kong's raw file-log (source of truth)
  raw/<session>_call<N>_request.json / _response.(sse|json)   literal raw wire
"""
import base64, glob, json, os, shutil, collections

HERE = os.path.dirname(os.path.abspath(__file__))
LOGDIR = os.path.join(HERE, "out", "logs")
OUT = os.path.join(HERE, "out", "engineering")


def user_prompt_of(body_json):
    try:
        b = json.loads(body_json)
    except Exception:
        return None
    msgs = b.get("messages", [])
    for m in reversed(msgs):
        if m.get("role") == "user":
            c = m.get("content")
            if isinstance(c, str):
                return c
            if isinstance(c, list):
                texts = [x.get("text") for x in c if isinstance(x, dict) and x.get("type") == "text"
                         and not str(x.get("text", "")).lstrip().startswith("<system-reminder>")]
                if texts:
                    return texts[-1]
    return None


def load_records():
    path = os.path.join(LOGDIR, "kong.jsonl")
    recs = []
    for line in open(path):
        line = line.strip()
        if line:
            try: recs.append(json.loads(line))
            except Exception: pass
    return recs


def main():
    os.makedirs(OUT, exist_ok=True)
    os.makedirs(os.path.join(OUT, "raw"), exist_ok=True)
    recs = load_records()
    shutil.copy(os.path.join(LOGDIR, "kong.jsonl"), os.path.join(OUT, "kong.jsonl"))

    # group model calls by session (a session = one user prompt + all its calls)
    by_session = collections.OrderedDict()
    for r in recs:
        s = r.get("straiker", {})
        sid = s.get("session_id") or "no-session"
        by_session.setdefault(sid, []).append(r)

    structured = []
    md = []
    md.append("# Kong → Straiker mapping (real Claude Code traffic)\n")
    md.append("Exported **from Kong's file-log** (`kong.jsonl`). For every real model call "
              "Kong proxied, this shows the user prompt, the raw request Kong received, "
              "what the `straiker-coding` plugin synthesized, the **exact payload it POSTed "
              "to Straiker** (and how), and Straiker's verdict.\n")
    md.append("## Flow\n")
    md.append("```")
    md.append("Claude Code ─HTTP─▶ Kong DP (straiker-coding plugin) ─┬─▶ upstream (Anthropic / Bedrock)")
    md.append("                                                      └─▶ Straiker /api/v1/detect  (x-tool: claude-code, HMAC-signed)")
    md.append("Per model call the plugin: parses the raw request → synthesizes Claude Code hook")
    md.append("events (UserPromptSubmit / PreToolUse / PostToolUse) → POSTs each to Straiker →")
    md.append("records the verdict. Utility/title-gen calls (0 tools) are not scored.")
    md.append("```\n")

    # global counters
    tot_calls = tot_events = 0
    ev_counter = collections.Counter()
    backends = collections.Counter()

    sess_n = 0
    for sid, calls in by_session.items():
        # order calls by start time
        calls.sort(key=lambda r: r.get("started_at", 0))
        # find the user prompt from the first scored event or the request body
        prompt = None
        for r in calls:
            for e in r.get("straiker", {}).get("events", []):
                if e.get("hook_event_name") == "UserPromptSubmit" and e.get("detect_payload", {}).get("prompt"):
                    prompt = e["detect_payload"]["prompt"]; break
            if prompt: break
        if not prompt:
            for r in calls:
                p = user_prompt_of(r.get("straiker", {}).get("request_body", "") or "")
                if p: prompt = p; break

        route = (calls[0].get("route") or {})
        svc = (calls[0].get("service") or {})
        backend = "bedrock" if any("/model" in (r.get("request", {}).get("uri", "")) for r in calls) else "anthropic"
        backends[backend] += 1
        sess_n += 1
        md.append(f"\n---\n\n## Session {sess_n}: `{sid}`  ({backend})\n")
        md.append(f"**User prompt:** `{(prompt or '(none)')[:300]}`\n")
        md.append(f"**Model calls Kong saw:** {len(calls)}\n")

        for ci, r in enumerate(calls, 1):
            s = r.get("straiker", {})
            req = r.get("request", {}); resp = r.get("response", {})
            lat = r.get("latencies", {})
            events = s.get("events", [])
            kind = "utility/title-gen (not scored)" if not events else "scored"
            tot_calls += 1
            md.append(f"\n### Call {ci} — {kind}\n")
            md.append(f"- **Raw Kong request:** `{req.get('method')} {req.get('uri','')}` — "
                      f"**{s.get('request_bytes', req.get('size'))} bytes**, "
                      f"upstream `{svc.get('id','')[:8]}` route `{route.get('id','')[:8]}`")
            md.append(f"- **Kong latencies (ms):** proxy={lat.get('proxy')} kong={lat.get('kong')} upstream={lat.get('third_party') or lat.get('proxy')}")
            md.append(f"- **Response Kong returned:** {resp.get('status')} `{s.get('response_content_type','')}` — {s.get('response_bytes')} bytes")
            # save raw wire
            if s.get("request_body"):
                open(os.path.join(OUT, "raw", f"{sid}_call{ci}_request.json"), "w").write(s["request_body"])
            if s.get("response_body"):
                ext = "eventstream.b64" if s.get("response_encoding") == "base64" else ("sse" if "event-stream" in s.get("response_content_type", "") else "json")
                open(os.path.join(OUT, "raw", f"{sid}_call{ci}_response.{ext}"), "w").write(s["response_body"])
                md.append(f"- raw wire files: `raw/{sid}_call{ci}_request.json`, `raw/{sid}_call{ci}_response.{ext}`")
            if not events:
                md.append("- **Sent to Straiker:** nothing (0 tools → utility call, plugin skips scoring)")
            for e in events:
                tot_events += 1
                ev_counter[e["hook_event_name"]] += 1
                v = e.get("verdict", {})
                how = s.get("plugin", {})
                md.append(f"- **Synthesized event → Straiker:** `{e['hook_event_name']}`"
                          + (f" tool=`{e.get('tool_name')}`" if e.get("tool_name") else ""))
                md.append(f"    - POST `{how.get('sent_to')}`  headers: `x-tool: {how.get('x_tool')}`, `{how.get('signing')}`")
                md.append(f"    - exact payload: `{json.dumps(e.get('detect_payload'))[:220]}`")
                md.append(f"    - **Straiker verdict:** action=`{v.get('action')}` score=`{v.get('score')}` category=`{v.get('score_category')}` turn_id=`{v.get('turn_id')}`")
                structured.append({
                    "session_id": sid, "backend": backend, "call": ci,
                    "user_prompt": prompt,
                    "kong_request": {"method": req.get("method"), "uri": req.get("uri"), "bytes": s.get("request_bytes"), "status": resp.get("status")},
                    "synthesized_event": {"hook_event_name": e["hook_event_name"], "tool_name": e.get("tool_name"), "tool_input": e.get("tool_input")},
                    "sent_to_straiker": {"url": how.get("sent_to"), "x_tool": how.get("x_tool"), "signing": how.get("signing"), "payload": e.get("detect_payload")},
                    "straiker_verdict": v,
                })

    with open(os.path.join(OUT, "mapping.jsonl"), "w") as f:
        for r in structured:
            f.write(json.dumps(r) + "\n")

    md.insert(2, f"**Totals:** {sess_n} sessions ({dict(backends)}), {tot_calls} model calls, "
                 f"{tot_events} events sent to Straiker {dict(ev_counter)}.\n")
    open(os.path.join(OUT, "kong_straiker_mapping.md"), "w").write("\n".join(md))

    print(f"engineering export -> {OUT}")
    print(f"  sessions={sess_n} backends={dict(backends)} calls={tot_calls} events_to_straiker={tot_events} {dict(ev_counter)}")
    print(f"  files: kong_straiker_mapping.md, mapping.jsonl, kong.jsonl, raw/")


if __name__ == "__main__":
    main()
