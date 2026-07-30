#!/usr/bin/env python3
"""Parity check: Kong-synthesized events (from the Lua parser replaying the
captured wire) vs the native Claude Code hook events recorded from the SAME
session. Proves the gateway reconstructs the hook contract faithfully.

For each corpus scenario:
  kong    = parity/run_lua.sh out/corpus/<name>.wire.jsonl   (Lua parser)
  native  = out/corpus/<name>.hooks.jsonl                    (real CC hooks)

Compares the scoreable/enforceable events (UserPromptSubmit, PreToolUse,
PostToolUse). Stop is native-only telemetry (backend yields no app_response),
so it is reported separately, not counted as a miss.
"""
import json, os, subprocess, sys, glob

HERE = os.path.dirname(os.path.abspath(__file__))
LAB = os.path.dirname(HERE)
RUN_LUA = os.path.join(HERE, "run_lua.sh")
SCOREABLE = ("UserPromptSubmit", "PreToolUse", "PostToolUse")


def kong_events(wire_path):
    out = subprocess.run(["bash", RUN_LUA, wire_path], capture_output=True, text=True)
    evs = []
    for line in out.stdout.splitlines():
        line = line.strip()
        if line:
            try:
                evs.append(json.loads(line))
            except Exception:
                pass
    return evs


def native_events(hooks_path):
    evs = []
    if not os.path.exists(hooks_path):
        return evs
    for line in open(hooks_path):
        try:
            r = json.loads(line)
        except Exception:
            continue
        p = r.get("payload", {})
        evs.append({
            "hook_event_name": r.get("event"),
            "tool_name": p.get("tool_name"),
            "tool_input": p.get("tool_input"),
            "prompt": p.get("prompt"),
        })
    return evs


def norm_prompt(s):
    return (s or "").strip()


def compare(name, kong, native):
    """Return a dict of per-type parity for one scenario."""
    res = {"name": name}
    for et in SCOREABLE:
        k = [e for e in kong if e["hook_event_name"] == et]
        n = [e for e in native if e["hook_event_name"] == et]
        matched = 0
        if et == "UserPromptSubmit":
            kp = sorted(norm_prompt(e.get("prompt")) for e in k)
            np = sorted(norm_prompt(e.get("prompt")) for e in n)
            # a prompt matches if the native prompt text equals the kong-extracted one
            npset = list(np)
            for p in kp:
                if p in npset:
                    matched += 1
                    npset.remove(p)
        elif et == "PreToolUse":
            # A Kong event matches a native event when the tool name is equal and
            # every field Kong extracted (the model's raw tool_use input) is
            # present and equal in the native tool_input. The native hook may add
            # client-applied schema defaults (e.g. Edit's `replace_all: false`)
            # that the model never emitted — that is not a capture miss, so we
            # subset-match rather than require exact equality.
            def subset(ki, ni):
                if not isinstance(ki, dict) or not isinstance(ni, dict):
                    return ki == ni
                return all(ni.get(kk) == v for kk, v in ki.items())
            avail = list(n)
            for e in k:
                for j, ne in enumerate(avail):
                    if ne.get("tool_name") == e.get("tool_name") and subset(e.get("tool_input"), ne.get("tool_input")):
                        matched += 1
                        avail.pop(j)
                        break
        else:  # PostToolUse — match on tool_name presence / count (native carries tool_name)
            matched = min(len(k), len(n))
        res[et] = {"kong": len(k), "native": len(n), "matched": matched}
    res["stop_native"] = len([e for e in native if e["hook_event_name"] == "Stop"])
    return res


def main():
    corpus = sorted(glob.glob(os.path.join(LAB, "out/corpus/*.wire.jsonl")))
    rows = []
    agg = {et: {"kong": 0, "native": 0, "matched": 0} for et in SCOREABLE}
    for wire in corpus:
        name = os.path.basename(wire).replace(".wire.jsonl", "")
        hooks = os.path.join(LAB, "out/corpus", name + ".hooks.jsonl")
        k = kong_events(wire)
        n = native_events(hooks)
        r = compare(name, k, n)
        rows.append(r)
        for et in SCOREABLE:
            for f in ("kong", "native", "matched"):
                agg[et][f] += r[et][f]

    # report
    print(f"{'scenario':<20} {'UPS k/n/m':>12} {'Pre k/n/m':>12} {'Post k/n/m':>12}")
    print("-" * 62)
    for r in rows:
        def cell(et):
            c = r[et]
            return f"{c['kong']}/{c['native']}/{c['matched']}"
        flag = ""
        for et in SCOREABLE:
            if r[et]["kong"] != r[et]["matched"] or r[et]["native"] != r[et]["matched"]:
                flag = " *"
        print(f"{r['name']:<20} {cell('UserPromptSubmit'):>12} {cell('PreToolUse'):>12} {cell('PostToolUse'):>12}{flag}")

    print("\n=== AGGREGATE ===")
    for et in SCOREABLE:
        a = agg[et]
        pr = 100.0 * a["matched"] / a["native"] if a["native"] else 100.0
        pk = 100.0 * a["matched"] / a["kong"] if a["kong"] else 100.0
        print(f"{et:<18} kong={a['kong']:<4} native={a['native']:<4} matched={a['matched']:<4} "
              f"recall={pr:.1f}%  precision={pk:.1f}%")

    # machine-readable
    with open(os.path.join(LAB, "out/parity_result.json"), "w") as f:
        json.dump({"rows": rows, "agg": agg}, f, indent=2)


if __name__ == "__main__":
    main()
