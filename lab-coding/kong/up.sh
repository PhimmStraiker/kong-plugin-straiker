#!/usr/bin/env bash
# Render kong.yml with the Straiker key + mode, then bring up local DB-less Kong.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
MODE="${1:-monitor}"
set -a; . "$HERE/../.env"; set +a
mkdir -p "$HERE/out"
sed -e "s|__STRAIKER_KEY__|$STRAIKER_CODING_KEY|g" -e "s|__MODE__|$MODE|g" \
  "$HERE/kong.tmpl.yml" > "$HERE/out/kong.rendered.yml"
echo "rendered kong.yml (mode=$MODE)"
cd "$HERE"
docker compose up -d
echo "waiting for Kong admin..."
for i in $(seq 1 30); do
  if curl -sf http://localhost:8001/status >/dev/null 2>&1; then echo "Kong up"; break; fi
  sleep 2
done
curl -s http://localhost:8001/ | python3 -c "import sys,json;d=json.load(sys.stdin);print('plugins available: straiker-coding =', 'straiker-coding' in d.get('plugins',{}).get('available_on_server',{}))" 2>/dev/null || true
