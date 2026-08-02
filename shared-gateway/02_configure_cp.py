#!/usr/bin/env python3
"""Configure the SHARED gateway control plane (straiker-shared-kong-gateway):
register the straiker-coding schema, create the Anthropic + Bedrock services/routes,
attach the guardrail plugin (block + fail_open, debug/log off) and key-auth (per-user
keys) to each. Idempotent.

    set -a && source ../.env.konnect && set +a
    STRAIKER_CODING_KEY=... python3 02_configure_cp.py     # or it reads ../lab-coding/.env
"""
import json, os, urllib.request, urllib.error

HOST = os.environ.get("KONNECT_API_HOSTNAME", "us.api.konghq.com")
PAT = os.environ["KONNECT_PAT"]
HERE = os.path.dirname(os.path.abspath(__file__))
CPID = dict(l.strip().split("=", 1) for l in open(os.path.join(HERE, "cp.env")) if "=" in l)["SHARED_CP_ID"].strip('"')
BASE = f"https://{HOST}/v2/control-planes/{CPID}/core-entities"
REPO = os.path.abspath(os.path.join(HERE, ".."))
SCHEMA = open(os.path.join(REPO, "kong", "plugins", "straiker-coding", "schema.lua")).read()

KEY = os.environ.get("STRAIKER_CODING_KEY")
if not KEY:
    for line in open(os.path.join(REPO, "lab-coding", ".env")):
        if line.startswith("STRAIKER_CODING_KEY"): KEY = line.split("=", 1)[1].strip().strip('"')
assert KEY, "need STRAIKER_CODING_KEY (the Claude Code key)"

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
        except Exception: return e.code, {"raw": raw[:400].decode()}

def find(kind, name):
    c, d = req("GET", f"/{kind}?name={name}")
    return next((i for i in d.get("data", []) if i.get("name") == name), None) if c == 200 else None

def upsert_service(name, url):
    ex = find("services", name); body = {"name": name, "url": url}
    c, d = req("PUT", f"/services/{ex['id']}", body) if ex else req("POST", "/services", body)
    print(f"  service {name}: {c}"); return (d.get("id") or (ex or {}).get("id"))

def upsert_route(name, sid, paths):
    ex = find("routes", name)
    body = {"name": name, "paths": paths, "protocols": ["http", "https"], "strip_path": False, "service": {"id": sid}}
    c, d = req("PUT", f"/routes/{ex['id']}", body) if ex else req("POST", "/routes", body)
    print(f"  route {name} {paths}: {c}"); return (d.get("id") or (ex or {}).get("id"))

def upsert_plugin(sid, name, config, tag):
    c, d = req("GET", f"/services/{sid}/plugins")
    ex = next((p for p in d.get("data", []) if p.get("name") == name), None) if c == 200 else None
    body = {"name": name, "service": {"id": sid}, "config": config}
    c, d = req("PUT", f"/plugins/{ex['id']}", body) if ex else req("POST", "/plugins", body)
    print(f"  plugin {name} on {tag}: {c}" + ("" if c in (200, 201) else f"  {json.dumps(d)[:300]}"))

GUARD = {  # the shared-instance guardrail posture
    "api_key": KEY, "detect_url": "https://api.prod.straiker.ai/api/v1/detect",
    "x_tool": "claude-code", "mode": "block", "fail_open": True, "debug": False,
    "log_serialize": False, "chatter_filter": True, "sign_payloads": True,
    "session_header": "X-Straiker-Session-Id",
    "user_name_header": "X-Straiker-User-Name",      # fallback; key-auth consumer wins
    "user_name_default": "straiker-shared",
}
KEYAUTH = {"key_names": ["apikey"], "hide_credentials": True}

def main():
    print("1. register plugin schema")
    c, d = req("GET", "/plugin-schemas")
    ex = next((i for i in d.get("items", d.get("data", [])) if i.get("name") == "straiker-coding"), None) if c == 200 else None
    c, d = (req("PUT", "/plugin-schemas/straiker-coding", {"lua_schema": SCHEMA}) if ex
            else req("POST", "/plugin-schemas", {"lua_schema": SCHEMA}))
    print(f"   schema: {c}")

    print("2. Anthropic path")
    a = upsert_service("anthropic-coding", "https://api.anthropic.com")
    upsert_route("anthropic-messages", a, ["/v1/messages"])
    upsert_plugin(a, "straiker-coding", GUARD, "anthropic")
    upsert_plugin(a, "key-auth", KEYAUTH, "anthropic")

    print("3. Bedrock path")
    b = upsert_service("bedrock-coding", "https://bedrock-runtime.us-east-1.amazonaws.com")
    upsert_route("bedrock-invoke", b, ["/model"])
    upsert_plugin(b, "straiker-coding", GUARD, "bedrock")
    upsert_plugin(b, "key-auth", KEYAUTH, "bedrock")

    print(f"\ndone. control plane admin API:\n  {BASE}")

if __name__ == "__main__":
    main()
