#!/usr/bin/env python3
"""Corpus analyzer — the learnings behind the parser. Reads out/corpus/*.wire.jsonl
(+ hooks) and prints the wire->hook statistics that justify the plugin design:
chatter breakdown, payload sizes, tool distribution, session stability, SSE shape.
"""
import json, glob, os, statistics as st, collections

LAB = os.path.dirname(os.path.abspath(__file__))
CORPUS = os.path.join(LAB, "out/corpus")


def load(p):
    try:
        return [json.loads(l) for l in open(p)]
    except FileNotFoundError:
        return []


def main():
    wires = sorted(glob.glob(os.path.join(CORPUS, "*.wire.jsonl")))
    tot_calls = 0
    by_model = collections.Counter()
    zero_tool = 0            # utility/chatter calls (no tools)
    titlegen = 0
    main_turns = 0
    sys_sizes, tool_counts, req_bytes = [], [], []
    tool_use_total, tool_result_total = 0, 0
    sessions = set()
    sse_calls, json_calls = 0, 0
    tool_name_counter = collections.Counter()
    chatter_examples = collections.Counter()

    for w in wires:
        for r in load(w):
            b = r.get("req_body")
            if not isinstance(b, dict):
                continue
            tot_calls += 1
            model = b.get("model", "?")
            by_model[model] += 1
            tools = b.get("tools") or []
            msgs = b.get("messages") or []
            md = b.get("metadata") or {}
            uid = md.get("user_id")
            if isinstance(uid, str):
                try:
                    sessions.add(json.loads(uid).get("session_id"))
                except Exception:
                    pass
            if not tools:
                zero_tool += 1
                # classify the utility
                txt = json.dumps(msgs)[:2000].lower()
                if "title" in txt or "<session>" in txt:
                    titlegen += 1
                    chatter_examples["titlegen"] += 1
                elif "suggest" in txt:
                    chatter_examples["suggestion"] += 1
                elif "stepped away" in txt or "recap" in txt:
                    chatter_examples["recap"] += 1
                else:
                    chatter_examples["other-0tool"] += 1
            else:
                main_turns += 1
                sys_sizes.append(len(json.dumps(b.get("system") or "")))
                tool_counts.append(len(tools))
                req_bytes.append(r.get("req_bytes", 0))
            # count tool_use / tool_result across messages
            for m in msgs:
                c = m.get("content")
                if isinstance(c, list):
                    for blk in c:
                        if isinstance(blk, dict):
                            if blk.get("type") == "tool_result":
                                tool_result_total += 1
            # response tool_use
            if "resp_sse" in r:
                sse_calls += 1
                for ev in r["resp_sse"]:
                    d = ev.get("data")
                    if isinstance(d, dict) and ev.get("event") == "content_block_start":
                        cb = d.get("content_block", {})
                        if cb.get("type") == "tool_use":
                            tool_use_total += 1
                            tool_name_counter[cb.get("name")] += 1
            elif isinstance(r.get("resp_body"), dict):
                json_calls += 1

    def pct(x): return f"{100.0*x/tot_calls:.1f}%" if tot_calls else "0%"

    print(f"# Corpus statistics ({len(wires)} scenarios)\n")
    print(f"Total wire calls (model messages): {tot_calls}")
    print(f"Distinct sessions: {len(sessions)}")
    print(f"By model: {dict(by_model)}")
    print()
    print(f"Main turns (tool-bearing):     {main_turns} ({pct(main_turns)})")
    print(f"Utility/chatter (zero-tool):   {zero_tool} ({pct(zero_tool)})  -> dropped by chatter filter")
    print(f"  chatter breakdown: {dict(chatter_examples)}")
    print()
    if sys_sizes:
        print(f"System prompt size (bytes): min={min(sys_sizes)} median={int(st.median(sys_sizes))} max={max(sys_sizes)}")
    if tool_counts:
        print(f"Tools per main request:     min={min(tool_counts)} median={int(st.median(tool_counts))} max={max(tool_counts)}")
    if req_bytes:
        print(f"Main request size (bytes):  min={min(req_bytes)} median={int(st.median(req_bytes))} max={max(req_bytes)}")
    print()
    print(f"Response transport: SSE calls={sse_calls}  JSON calls={json_calls}")
    print(f"tool_use blocks in responses (PreToolUse candidates): {tool_use_total}")
    print(f"tool_result blocks in requests (PostToolUse candidates): {tool_result_total}")
    print(f"Tool usage: {dict(tool_name_counter.most_common(12))}")


if __name__ == "__main__":
    main()
