#!/usr/bin/env python3
"""Reconcile Kong <-> Straiker by session_id.

Parses the DP's `recon sid=<session> event=<E> status=<s> turn_id=<t>` log lines
(emitted by the plugin in debug mode) and joins them with the load CSV, producing
a table that maps each session_id to its Straiker turn_ids per event. This is the
proof that the same message is findable on both sides via session_id.

Usage:
    python3 reconcile.py --container straiker-konnect-dp --since <unix_ts>
"""
import argparse, csv, collections, json, os, re, subprocess

REC = re.compile(r"recon sid=(\S+) event=(\S+) status=(\S+) turn_id=(\S+)")


def harvest(container, since):
    cmd = ["docker", "logs", container]
    if since:
        cmd = ["docker", "logs", "--since", str(since), container]
    out = subprocess.run(cmd, capture_output=True, text=True)
    by_sid = collections.defaultdict(list)
    for line in (out.stdout + out.stderr).splitlines():
        m = REC.search(line)
        if m:
            sid, event, status, turn = m.groups()
            by_sid[sid].append({"event": event, "status": status, "turn_id": turn})
    return by_sid


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--container", default="straiker-konnect-dp")
    ap.add_argument("--since", default=None)
    ap.add_argument("--csv", default=os.path.join(os.path.dirname(__file__), "out", "load_reconcile.csv"))
    ap.add_argument("--out", default=os.path.join(os.path.dirname(__file__), "out", "reconciliation.csv"))
    args = ap.parse_args()

    by_sid = harvest(args.container, args.since)
    # load CSV meta (tool/flavor/backend per session)
    meta = {}
    if os.path.exists(args.csv):
        for r in csv.DictReader(open(args.csv)):
            meta.setdefault(r["session_id"], {"backend": r["backend"], "tools": set(), "flavors": set()})
            meta[r["session_id"]]["tools"].add(r["tool"])
            meta[r["session_id"]]["flavors"].add(r["flavor"])

    rows = []
    for sid, evs in sorted(by_sid.items()):
        m = meta.get(sid, {})
        events = ",".join(f"{e['event']}:{e['turn_id'][:8]}" for e in evs)
        rows.append({
            "session_id": sid,
            "backend": m.get("backend", sid.split("-")[1] if "-" in sid else "?"),
            "tools": "|".join(sorted(m.get("tools", []))),
            "flavors": "|".join(sorted(m.get("flavors", []))),
            "n_events": len(evs),
            "events_turns": events,
        })

    with open(args.out, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=["session_id", "backend", "tools", "flavors", "n_events", "events_turns"])
        w.writeheader(); w.writerows(rows)

    n_turns = sum(len(v) for v in by_sid.values())
    ab = collections.Counter(r["backend"] for r in rows)
    print(f"sessions reconciled: {len(rows)}   total turns: {n_turns}   by backend: {dict(ab)}")
    print(f"reconciliation table: {args.out}\n")
    print("sample (session_id -> event:turn_id …):")
    for r in rows[:8]:
        print(f"  {r['session_id']}  [{r['tools']}]  {r['events_turns']}")


if __name__ == "__main__":
    main()
