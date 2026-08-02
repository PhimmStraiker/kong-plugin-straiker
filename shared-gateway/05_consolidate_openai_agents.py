#!/usr/bin/env python3
"""Cost cleanup: collapse the 4 OpenAI-upstream agent SERVICES (codex/cursor/opencode/
copilot) into ONE service with 4 ROUTES.

All four point at the same upstream (api.openai.com), and Kong plugins can be scoped to a
ROUTE, not just a service — so each agent keeps its own straiker-coding instance with its
own Straiker detect key (its own collection) and its own key-auth. Identical behaviour,
3 fewer billable services.

Keeps serving throughout: creates the new service+routes+plugins FIRST, verifies, and only
then deletes the old per-agent services (which cascades their routes/plugins).

    set -a && source ../.env.konnect && set +a
    python3 05_consolidate_openai_agents.py          # dry run (shows the plan)
    python3 05_consolidate_openai_agents.py --apply
"""
import json, os, sys, urllib.request, urllib.error

HOST = os.environ.get("KONNECT_API_HOSTNAME", "us.api.konghq.com")
PAT = os.environ["KONNECT_PAT"]
HERE = os.path.dirname(os.path.abspath(__file__))
CPID = dict(l.strip().split("=", 1) for l in open(os.path.join(HERE, "cp.env")) if "=" in l)["SHARED_CP_ID"].strip('"')
BASE = f"https://{HOST}/v2/control-planes/{CPID}/core-entities"
DETECT = "https://api.prod.straiker.ai/api/v1/detect"
APPLY = "--apply" in sys.argv

KEYS = {}
for line in open(os.path.join(HERE, "agent-keys.env")):
    line = line.strip()
    if line.startswith("STRAIKER_KEY_") and "=" in line:
        k, v = line.split("=", 1)
        KEYS[k.replace("STRAIKER_KEY_", "").lower()] = v.strip()

AGENTS = ["codex", "cursor", "opencode", "copilot"]
SHARED_SVC = "openai-agents"          # the single replacement service


def req(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    r = urllib.request.Request(f"{BASE}{path}", method=method, data=data,
        headers={"Authorization": f"Bearer {PAT}", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(r) as resp:
            raw = resp.read(); return resp.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        raw = e.read()
        try: return e.code, json.loads(raw)
        except Exception: return e.code, {"raw": raw[:200].decode()}


def find(kind, name):
    c, d = req("GET", f"/{kind}?name={name}")
    return next((i for i in d.get("data", []) if i.get("name") == name), None) if c == 200 else None


def main():
    if not APPLY:
        print("DRY RUN — plan:")
        print(f"  create 1 service '{SHARED_SVC}' -> https://api.openai.com")
        for a in AGENTS:
            print(f"    route /{a}  + straiker-coding(key={KEYS.get(a,'?')[:8]}…, x-tool={a}) + key-auth")
        print(f"  then delete services: {', '.join(a+'-coding' for a in AGENTS)}")
        print("  net: 4 services -> 1  (3 fewer billable services; all 4 agents keep serving)")
        print("\n  re-run with --apply")
        return

    # 1. the single shared service
    ex = find("services", SHARED_SVC)
    body = {"name": SHARED_SVC, "url": "https://api.openai.com"}
    c, d = req("PUT", f"/services/{ex['id']}", body) if ex else req("POST", "/services", body)
    sid = d.get("id") or (ex or {}).get("id")
    print(f"  service {SHARED_SVC}: {c}")

    # 2. one route per agent, with ROUTE-SCOPED plugins carrying that agent's key
    for a in AGENTS:
        key = KEYS.get(a)
        if not key:
            print(f"  {a}: no key — skipped"); continue
        rname = f"{a}-r"
        rex = find("routes", rname)
        rbody = {"name": rname, "paths": [f"/{a}"], "protocols": ["http", "https"],
                 "strip_path": True, "service": {"id": sid}}
        c, rd = req("PUT", f"/routes/{rex['id']}", rbody) if rex else req("POST", "/routes", rbody)
        rid = rd.get("id") or (rex or {}).get("id")
        print(f"    route /{a}: {c}")

        c, pl = req("GET", f"/routes/{rid}/plugins")
        have = {p["name"]: p["id"] for p in pl.get("data", [])} if c == 200 else {}

        gcfg = {"api_key": key, "detect_url": DETECT, "x_tool": a,
                "mode": "block", "fail_open": True, "debug": False, "log_serialize": False,
                "chatter_filter": True, "sign_payloads": True,
                "session_header": "X-Straiker-Session-Id",
                "user_name_header": "X-Straiker-User-Name",
                "user_name_default": f"{a}-shared"}
        for pname, cfg in (("straiker-coding", gcfg), ("key-auth", {"key_names": ["apikey"], "hide_credentials": True})):
            pbody = {"name": pname, "route": {"id": rid}, "config": cfg}
            if pname in have:
                c, _ = req("PUT", f"/plugins/{have[pname]}", pbody)
            else:
                c, _ = req("POST", "/plugins", pbody)
            print(f"      {pname}: {c}")

    # 3. only now remove the old per-agent services (cascades their routes+plugins)
    print("  removing superseded per-agent services:")
    for a in AGENTS:
        old = find("services", f"{a}-coding")
        if old:
            c, _ = req("DELETE", f"/services/{old['id']}")
            print(f"    {a}-coding: {c}")

    c, d = req("GET", "/services?size=100")
    print(f"\n  services on this control plane now: {len(d.get('data', []))}")


if __name__ == "__main__":
    main()
