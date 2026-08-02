#!/usr/bin/env python3
"""Create (idempotently) a dedicated Konnect control plane for the SHARED public
Claude Code guardrail gateway — separate from the SE-demo CP — generate a data-plane
client cert, pin it, and write the data-plane cluster config for the App Runner image.

    set -a && source ../.env.konnect && set +a   # for KONNECT_PAT + KONNECT_API_HOSTNAME
    python3 01_create_control_plane.py

Outputs: ./secrets/tls.crt, ./secrets/tls.key, ./cp.env  (git-ignored)
"""
import json, os, subprocess, urllib.request, urllib.error

HOST = os.environ.get("KONNECT_API_HOSTNAME", "us.api.konghq.com")
PAT = os.environ["KONNECT_PAT"]
BASE = f"https://{HOST}/v2"
NAME = "straiker-shared-kong-gateway"
DESC = "Shared Straiker-guardrailed Claude Code gateway (public instance; key-auth gated, per-user keys)."
HERE = os.path.dirname(os.path.abspath(__file__))
SEC = os.path.join(HERE, "secrets"); os.makedirs(SEC, exist_ok=True)

def api(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    r = urllib.request.Request(BASE + path, method=method, data=data,
        headers={"Authorization": f"Bearer {PAT}", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(r) as resp:
            raw = resp.read(); return resp.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        raw = e.read()
        try: return e.code, json.loads(raw)
        except Exception: return e.code, {"raw": raw[:500].decode()}

# 1. find-or-create the control plane
c, d = api("GET", "/control-planes?filter%5Bname%5D=" + NAME)
existing = next((cp for cp in d.get("data", []) if cp.get("name") == NAME), None) if c == 200 else None
if existing:
    cp = existing; print(f"control plane exists: {cp['id']}")
else:
    c, cp = api("POST", "/control-planes", {
        "name": NAME, "description": DESC,
        "cluster_type": "CLUSTER_TYPE_CONTROL_PLANE", "auth_type": "pinned_client_certs"})
    if c not in (200, 201): raise SystemExit(f"create failed: {c} {json.dumps(cp)[:400]}")
    print(f"created control plane: {cp['id']}")

CPID = cp["id"]
conf = cp.get("config") or {}
cp_ep = conf.get("control_plane_endpoint", "").replace("https://", "").rstrip("/")
tp_ep = conf.get("telemetry_endpoint", "").replace("https://", "").rstrip("/")

# 2. generate a DP client cert if we don't have one yet
crt, key = os.path.join(SEC, "tls.crt"), os.path.join(SEC, "tls.key")
if not (os.path.exists(crt) and os.path.exists(key)):
    subprocess.run(["openssl", "req", "-new", "-x509", "-nodes", "-newkey", "rsa:2048",
        "-keyout", key, "-out", crt, "-days", "1095", "-subj", "/CN=konggw-shared-dp"], check=True)
    os.chmod(key, 0o600)
    print("generated DP client cert")
cert_pem = open(crt).read()

# 3. pin the cert to the control plane (idempotent-ish: ignore 409/duplicate)
c, d = api("POST", f"/control-planes/{CPID}/dp-client-certificates", {"cert": cert_pem})
print(f"pin cert: {c}" + ("" if c in (200, 201) else f"  {json.dumps(d)[:200]}"))

# 4. emit the DP cluster config for the App Runner image
env = {
    "SHARED_CP_ID": CPID,
    "KONG_CLUSTER_CONTROL_PLANE": f"{cp_ep}:443",
    "KONG_CLUSTER_SERVER_NAME": cp_ep,
    "KONG_CLUSTER_TELEMETRY_ENDPOINT": f"{tp_ep}:443",
    "KONG_CLUSTER_TELEMETRY_SERVER_NAME": tp_ep,
}
with open(os.path.join(HERE, "cp.env"), "w") as f:
    for k, v in env.items(): f.write(f'{k}="{v}"\n')
print("\n=== shared gateway control plane ready ===")
for k, v in env.items(): print(f"  {k}={v}")
print(f"  admin API: {BASE}/control-planes/{CPID}/core-entities")
print("  wrote cp.env + secrets/tls.{crt,key}")
