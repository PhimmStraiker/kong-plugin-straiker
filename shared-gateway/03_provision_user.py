#!/usr/bin/env python3
"""Provision (or revoke) a teammate's access to the shared gateway: a Kong consumer
(their email = their identity in the Straiker Console) + a key-auth key.

    set -a && source ../.env.konnect && set +a
    python3 03_provision_user.py add  alice@straiker.ai
    python3 03_provision_user.py list
    python3 03_provision_user.py revoke alice@straiker.ai
"""
import json, os, sys, urllib.request, urllib.error

HOST = os.environ.get("KONNECT_API_HOSTNAME", "us.api.konghq.com")
PAT = os.environ["KONNECT_PAT"]
HERE = os.path.dirname(os.path.abspath(__file__))
CPID = dict(l.strip().split("=", 1) for l in open(os.path.join(HERE, "cp.env")) if "=" in l)["SHARED_CP_ID"].strip('"')
BASE = f"https://{HOST}/v2/control-planes/{CPID}/core-entities"
GW = "https://konggw.dev.straiker.ai"

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
        except Exception: return e.code, {"raw": raw[:300].decode()}

def all_consumers():
    """List every consumer, following pagination.

    NB: Konnect IGNORES ?username= — it returns the full list regardless — so filtering
    must happen client-side over ALL pages. Relying on the query param silently returned
    the wrong answer and left a revoked user's key live.
    """
    out, offset = [], None
    while True:
        c, d = req("GET", "/consumers?size=100" + (f"&offset={offset}" if offset else ""))
        if c != 200:
            break
        out += d.get("data", [])
        offset = d.get("offset")
        if not offset:
            break
    return out


def find_consumer(username):
    return next((x for x in all_consumers() if x.get("username") == username), None)

def add(email):
    ex = find_consumer(email)
    if ex: cid = ex["id"]; print(f"consumer exists: {email}")
    else:
        c, d = req("POST", "/consumers", {"username": email})
        if c not in (200, 201): raise SystemExit(f"consumer create failed: {c} {d}")
        cid = d["id"]; print(f"created consumer: {email}")
    c, d = req("POST", f"/consumers/{cid}/key-auth", {})   # auto-generate a key
    if c not in (200, 201): raise SystemExit(f"key create failed: {c} {d}")
    key = d["key"]
    print("\n=== send this to the teammate ===")
    print(f"  identity : {email}")
    print(f"  key      : {key}")
    print(f"  base URL : {GW}")
    print( "  setup    : export KONGGW_KEY='%s'; source konggw-toggle.sh; konggw-on" % key)

def revoke(email):
    ex = find_consumer(email)
    if not ex: print(f"no such consumer: {email}"); return
    req("DELETE", f"/consumers/{ex['id']}")   # deletes the consumer + its keys
    print(f"revoked: {email}")

def lst():
    c, d = req("GET", "/consumers?size=1000")
    for x in d.get("data", []): print(f"  {x.get('username')}  ({x['id'][:8]})")

if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "list"
    if cmd == "add": add(sys.argv[2])
    elif cmd == "revoke": revoke(sys.argv[2])
    else: lst()
