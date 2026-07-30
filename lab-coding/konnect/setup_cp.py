#!/usr/bin/env python3
"""Configure the Konnect control plane (straiker-se-demo) for the coding-agent
demo: register the straiker-coding plugin schema, then create services + routes
+ plugins for the Anthropic (/v1/messages) and Bedrock (/model) paths.

The self-managed data plane supplies the plugin CODE; Konnect validates config
against the schema registered here. Run:
    set -a && source .env.konnect && set +a
    STRAIKER_CODING_KEY=... python3 lab-coding/konnect/setup_cp.py
"""
import json, os, urllib.request, urllib.error

CP = os.environ["KONNECT_ADMIN_API"].rstrip("/")
PAT = os.environ["KONNECT_PAT"]
KEY = os.environ["STRAIKER_CODING_KEY"]
REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
SCHEMA = open(os.path.join(REPO, "kong", "plugins", "straiker-coding", "schema.lua")).read()


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


def find(kind, name):
    c, d = req("GET", f"/core-entities/{kind}?name={name}")
    if c != 200:
        return None
    for i in d.get("data", []):
        if i.get("name") == name:
            return i
    return None


def upsert_service(name, url):
    ex = find("services", name)
    body = {"name": name, "url": url}
    if ex:
        c, d = req("PATCH", f"/core-entities/services/{ex['id']}", body)
    else:
        c, d = req("POST", "/core-entities/services", body)
    print(f"  service {name}: {c}")
    return d.get("id") or (ex or {}).get("id")


def upsert_route(name, service_id, paths):
    ex = find("routes", name)
    body = {"name": name, "paths": paths, "protocols": ["http", "https"],
            "strip_path": False, "service": {"id": service_id}}
    if ex:
        c, d = req("PATCH", f"/core-entities/routes/{ex['id']}", body)
    else:
        c, d = req("POST", "/core-entities/routes", body)
    print(f"  route {name} {paths}: {c}")
    return d.get("id") or (ex or {}).get("id")


def upsert_plugin(service_id, tag):
    # find existing straiker-coding plugin on this service
    c, d = req("GET", f"/core-entities/services/{service_id}/plugins")
    ex = next((p for p in d.get("data", []) if p.get("name") == "straiker-coding"), None) if c == 200 else None
    cfg = {"name": "straiker-coding", "service": {"id": service_id},
           "config": {"api_key": KEY,
                      "detect_url": "https://api.prod.straiker.ai/api/v1/detect",
                      "mode": "monitor", "chatter_filter": True,
                      "session_header": "X-Straiker-Session-Id",
                      "user_name_default": "konnect-coding-demo",
                      "debug": True}}
    if ex:
        c, d = req("PATCH", f"/core-entities/plugins/{ex['id']}", cfg)
    else:
        c, d = req("POST", "/core-entities/plugins", cfg)
    print(f"  plugin straiker-coding on {tag}: {c}")
    if c not in (200, 201):
        print(f"    -> {json.dumps(d)[:400]}")


def main():
    print("1. register plugin schema")
    c, d = req("GET", "/core-entities/plugin-schemas")
    ex = next((i for i in d.get("items", d.get("data", [])) if i.get("name") == "straiker-coding"), None) if c == 200 else None
    if ex:
        c, d = req("PUT", "/core-entities/plugin-schemas/straiker-coding", {"lua_schema": SCHEMA})
    else:
        c, d = req("POST", "/core-entities/plugin-schemas", {"lua_schema": SCHEMA})
    print(f"  schema register: {c}" + ("" if c in (200, 201) else f"  -> {json.dumps(d)[:400]}"))

    print("2. anthropic service/route/plugin")
    s = upsert_service("anthropic-coding", "https://api.anthropic.com")
    upsert_route("anthropic-messages", s, ["/v1/messages"])
    upsert_plugin(s, "anthropic")

    print("3. bedrock service/route/plugin")
    b = upsert_service("bedrock-coding", "https://bedrock-runtime.us-east-1.amazonaws.com")
    upsert_route("bedrock-invoke", b, ["/model"])
    upsert_plugin(b, "bedrock")

    print("done.")


if __name__ == "__main__":
    main()
