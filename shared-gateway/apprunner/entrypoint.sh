#!/usr/bin/env bash
# Materialize the Konnect cluster cert/key from base64 env (App Runner secrets),
# then hand off to Kong's normal startup. All other KONG_* config comes from the
# App Runner service env (see deploy.sh).
set -euo pipefail

CERT_DIR="${CERT_DIR:-/tmp/konggw}"
mkdir -p "$CERT_DIR"

if [ -n "${KONG_CLUSTER_CERT_B64:-}" ]; then
  echo "$KONG_CLUSTER_CERT_B64" | base64 -d > "$CERT_DIR/tls.crt"
  export KONG_CLUSTER_CERT="$CERT_DIR/tls.crt"
fi
if [ -n "${KONG_CLUSTER_CERT_KEY_B64:-}" ]; then
  echo "$KONG_CLUSTER_CERT_KEY_B64" | base64 -d > "$CERT_DIR/tls.key"
  chmod 600 "$CERT_DIR/tls.key"
  export KONG_CLUSTER_CERT_KEY="$CERT_DIR/tls.key"
fi

# hand off to the stock Kong entrypoint (data_plane role comes from KONG_ROLE env).
# NB: in kong/kong-gateway:3.x this is /entrypoint.sh (NOT /docker-entrypoint.sh).
exec /entrypoint.sh kong docker-start
