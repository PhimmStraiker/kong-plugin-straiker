#!/usr/bin/env python3
"""Flip the DEPLOYED straiker-coding plugin(s) to a production enforcement posture:

    mode      = block   -> the plugin HONORS Straiker's verdict (enforces a deny)
    fail_open = true    -> if Straiker is unreachable/errors/times out, ALLOW (never
                           break coding on a guardrail outage)
    debug     = false   -> REQUIRED for enforcement: Straiker-Debug:TRUE and enforcement
                           are mutually exclusive (debug returns the score breakdown
                           instead of the deny decision)

The actual block / detect / disable policy per category is controlled at the STRAIKER
Console level — this just makes the gateway a faithful enforcer of whatever Straiker
decides. Preserves every other config field. Idempotent. Hybrid DP picks up the change
from the control plane within seconds (no container restart).

    set -a && source lab-coding/.env.konnect && set +a
    python3 lab-coding/konnect/set_plugin_config.py
"""
import json, os, urllib.request, urllib.error

CP = os.environ["KONNECT_ADMIN_API"].rstrip("/")
PAT = os.environ["KONNECT_PAT"]
# Identity: Claude Code's wire traffic carries only a session UUID, not who the user is.
# So attribute via (a) a per-request header the plugin reads -> per-developer identity, and
# (b) a default that identifies the gateway owner when no header is present.
USER_NAME = os.environ.get("STRAIKER_USER", "phimmasone@straiker.ai")
OVERRIDES = {"mode": "block", "fail_open": True, "debug": False,
             "user_name_header": "X-Straiker-User-Name",
             "user_name_default": USER_NAME}


def req(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    r = urllib.request.Request(f"{CP}{path}", method=method, data=data,
        headers={"Authorization": f"Bearer {PAT}", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(r) as resp:
            raw = resp.read(); return resp.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        raw = e.read()
        try: return e.code, json.loads(raw)
        except Exception: return e.code, {"raw": raw[:400].decode()}


def all_coding_plugins():
    plugins, offset = [], None
    while True:
        path = "/core-entities/plugins?size=100" + (f"&offset={offset}" if offset else "")
        c, d = req("GET", path)
        if c != 200:
            raise SystemExit(f"list plugins failed: {c} {d}")
        plugins += [p for p in d.get("data", []) if p.get("name") == "straiker-coding"]
        offset = d.get("offset")
        if not offset:
            return plugins


def main():
    plugins = all_coding_plugins()
    if not plugins:
        raise SystemExit("no straiker-coding plugins found on the control plane")
    print(f"updating {len(plugins)} straiker-coding plugin(s) -> {OVERRIDES}")
    for p in plugins:
        cfg = dict(p.get("config") or {})
        cfg.update(OVERRIDES)
        body = {"name": "straiker-coding", "config": cfg}
        for scope in ("service", "route", "consumer"):
            if p.get(scope):
                body[scope] = {"id": p[scope]["id"]}
        c, d = req("PUT", f"/core-entities/plugins/{p['id']}", body)
        tag = (p.get("service") or p.get("route") or {}).get("id", "?")[:8]
        print(f"  PUT {p['id'][:8]} (scope {tag}): {c}")
        if c not in (200, 201):
            print(f"    -> {json.dumps(d)[:400]}")
    # verify from a fresh read
    print("verify (fresh read):")
    for p in all_coding_plugins():
        cf = p.get("config") or {}
        print(f"  {p['id'][:8]}: mode={cf.get('mode')} fail_open={cf.get('fail_open')} "
              f"debug={cf.get('debug')} user_name_header={cf.get('user_name_header')} "
              f"user_name_default={cf.get('user_name_default')}")


if __name__ == "__main__":
    main()
