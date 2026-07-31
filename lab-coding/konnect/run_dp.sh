#!/usr/bin/env bash
# Run a Konnect-connected data plane (hybrid mode) with the straiker-coding
# plugin mounted, pulling config from the straiker-se-demo control plane. Traffic
# through this DP shows in Konnect Analytics AND is guardrailed by Straiker.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
set -a; . "$REPO/.env.konnect"; set +a

TLS="$HERE/out"; mkdir -p "$TLS"
# cluster cert/key may be inline PEM or a path — normalise to files
emit() { # $1 var value  $2 outfile
  if printf '%s' "$1" | grep -q "BEGIN"; then printf '%s\n' "$1" > "$2"; else cp "$1" "$2"; fi
}
emit "$KONG_CLUSTER_CERT" "$TLS/tls.crt"
emit "$KONG_CLUSTER_CERT_KEY" "$TLS/tls.key"
chmod 600 "$TLS/tls.key"
mkdir -p "$TLS/capture"; chmod 777 "$TLS/capture"   # raw-body capture (kong user writes here)

docker rm -f straiker-konnect-dp >/dev/null 2>&1 || true

docker run -d --name straiker-konnect-dp \
  -e "KONG_ROLE=data_plane" \
  -e "KONG_DATABASE=off" \
  -e "KONG_KONNECT_MODE=on" \
  -e "KONG_CLUSTER_MTLS=pki" \
  -e "KONG_CLUSTER_CONTROL_PLANE=${KONG_CLUSTER_CONTROL_PLANE}" \
  -e "KONG_CLUSTER_SERVER_NAME=${KONG_CLUSTER_SERVER_NAME}" \
  -e "KONG_CLUSTER_TELEMETRY_ENDPOINT=${KONG_CLUSTER_TELEMETRY_ENDPOINT}" \
  -e "KONG_CLUSTER_TELEMETRY_SERVER_NAME=${KONG_CLUSTER_TELEMETRY_SERVER_NAME}" \
  -e "KONG_CLUSTER_CERT=/kong/tls.crt" \
  -e "KONG_CLUSTER_CERT_KEY=/kong/tls.key" \
  -e "KONG_LUA_SSL_TRUSTED_CERTIFICATE=system" \
  -e "KONG_PLUGINS=bundled,straiker,straiker-coding" \
  -e "KONG_NGINX_HTTP_LUA_SHARED_DICT=straiker_coding 32m" \
  -e "KONG_NGINX_HTTP_CLIENT_BODY_BUFFER_SIZE=16m" \
  -e "KONG_NGINX_HTTP_CLIENT_MAX_BODY_SIZE=0" \
  -e "KONG_PROXY_LISTEN=0.0.0.0:8000" \
  -e "KONG_STATUS_LISTEN=0.0.0.0:8100" \
  -e "KONG_LOG_LEVEL=notice" \
  -v "$REPO/kong/plugins/straiker:/usr/local/share/lua/5.1/kong/plugins/straiker:ro" \
  -v "$REPO/kong/plugins/straiker-coding:/usr/local/share/lua/5.1/kong/plugins/straiker-coding:ro" \
  -v "$TLS/capture:/straiker-capture" \
  -v "$TLS/tls.crt:/kong/tls.crt:ro" \
  -v "$TLS/tls.key:/kong/tls.key:ro" \
  -p 8000:8000 -p 8100:8100 \
  "kong/kong-gateway:${KONG_GATEWAY_VERSION:-3.14}" >/dev/null

echo "DP starting; waiting for it to become ready + connect to Konnect..."
for i in $(seq 1 30); do
  if curl -sf http://localhost:8100/status >/dev/null 2>&1; then echo "DP ready on :8000 (proxy)"; break; fi
  sleep 2
done
docker logs straiker-konnect-dp 2>&1 | grep -iE "started|konnect|cluster|error" | tail -5 || true
