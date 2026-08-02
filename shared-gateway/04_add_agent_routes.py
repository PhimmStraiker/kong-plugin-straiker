#!/usr/bin/env python3
"""Add per-agent routes to the shared gateway — one route + one straiker-coding plugin
instance per agent, each carrying ITS OWN Straiker detect key so events land in that
agent's own collection (never mixed into the Claude Code one).

Path-prefixed because several agents share a wire format (Cursor and OpenCode both POST
/v1/chat/completions) and a Kong plugin instance holds exactly one api_key — so the
agent must be distinguishable by route.

    agent      base URL to configure in the client              -> upstream
    codex      https://konggw.dev.straiker.ai/codex/v1          -> api.openai.com/v1/responses
    cursor     https://konggw.dev.straiker.ai/cursor/v1         -> api.openai.com/v1/chat/completions
    opencode   https://konggw.dev.straiker.ai/opencode/v1       -> api.openai.com/v1/chat/completions
    copilot    https://konggw.dev.straiker.ai/copilot/v1        -> api.openai.com/v1/chat/completions
    (claude code keeps the root /v1/messages + /model routes)

    set -a && source ../.env.konnect && set +a
    python3 04_add_agent_routes.py
"""
import json, os, urllib.request, urllib.error

HOST = os.environ.get("KONNECT_API_HOSTNAME", "us.api.konghq.com")
PAT = os.environ["KONNECT_PAT"]
HERE = os.path.dirname(os.path.abspath(__file__))
CPID = dict(l.strip().split("=", 1) for l in open(os.path.join(HERE, "cp.env")) if "=" in l)["SHARED_CP_ID"].strip('"')
BASE = f"https://{HOST}/v2/control-planes/{CPID}/core-entities"
DETECT = "https://api.prod.straiker.ai/api/v1/detect"

# per-agent Straiker detect keys — each agent gets its OWN collection
KEYS = {}
for line in open(os.path.join(HERE, "agent-keys.env")):
    line = line.strip()
    if line.startswith("STRAIKER_KEY_") and "=" in line:
        k, v = line.split("=", 1)
        KEYS[k.replace("STRAIKER_KEY_", "").lower()] = v.strip()

OPENAI = "https://api.openai.com"
AGENTS = [
    # (agent, path prefix, upstream, x_tool)
    ("codex",    "/codex",    OPENAI, "codex"),
    ("cursor",   "/cursor",   OPENAI, "cursor"),
    ("opencode", "/opencode", OPENAI, "opencode"),
    ("copilot",  "/copilot",  OPENAI, "copilot"),
]


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


def find(kind, name):
    c, d = req("GET", f"/{kind}?name={name}")
    return next((i for i in d.get("data", []) if i.get("name") == name), None) if c == 200 else None


def upsert(kind, name, body):
    ex = find(kind, name)
    c, d = req("PUT", f"/{kind}/{ex['id']}", body) if ex else req("POST", f"/{kind}", body)
    return c, (d.get("id") or (ex or {}).get("id"))


def upsert_plugin_on_service(sid, pname, config, tag):
    c, d = req("GET", f"/services/{sid}/plugins")
    ex = next((p for p in d.get("data", []) if p.get("name") == pname), None) if c == 200 else None
    body = {"name": pname, "service": {"id": sid}, "config": config}
    c, _ = req("PUT", f"/plugins/{ex['id']}", body) if ex else req("POST", "/plugins", body)
    print(f"    {pname:16} {c}")


def main():
    for agent, prefix, upstream, x_tool in AGENTS:
        key = KEYS.get(agent)
        if not key:
            print(f"  {agent}: NO KEY in agent-keys.env — skipped"); continue
        print(f"  {agent}  {prefix}  -> {upstream}  (x-tool: {x_tool})")

        c, sid = upsert("services", f"{agent}-coding", {"name": f"{agent}-coding", "url": upstream})
        print(f"    service          {c}")
        # strip_path so /codex/v1/responses -> /v1/responses upstream
        c, _ = upsert("routes", f"{agent}-route", {
            "name": f"{agent}-route", "paths": [prefix], "protocols": ["http", "https"],
            "strip_path": True, "service": {"id": sid}})
        print(f"    route            {c}")

        upsert_plugin_on_service(sid, "straiker-coding", {
            "api_key": key, "detect_url": DETECT, "x_tool": x_tool,
            "mode": "block", "fail_open": True, "debug": False, "log_serialize": False,
            "chatter_filter": True, "sign_payloads": True,
            "session_header": "X-Straiker-Session-Id",
            "user_name_header": "X-Straiker-User-Name",
            "user_name_default": f"{agent}-shared",
        }, agent)
        upsert_plugin_on_service(sid, "key-auth", {"key_names": ["apikey"], "hide_credentials": True}, agent)

    print("\nclient config:")
    print("  codex    ~/.codex/config.toml  [model_providers.straiker] base_url=\"https://konggw.dev.straiker.ai/codex/v1\" wire_api=\"responses\"")
    print("  opencode opencode.json  provider.straiker.options.baseURL=\"https://konggw.dev.straiker.ai/opencode/v1\"")
    print("  cursor   Settings->Models->Override OpenAI Base URL = https://konggw.dev.straiker.ai/cursor/v1")


if __name__ == "__main__":
    main()
