#!/usr/bin/env bash
# Drive one headless Claude Code scenario through the wire proxy, capturing both
# the wire traffic (proxy -> out/<name>.wire.jsonl) and the hook events
# (recorder -> out/<name>.hooks.jsonl + out/<name>.detect.jsonl) from ONE session.
#
# Usage: run_session.sh <name> <prompt> [model]
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
NAME="${1:?scenario name}"; PROMPT="${2:?prompt}"; MODEL="${3:-claude-sonnet-4-5-20250929}"
PORT="${PORT:-8788}"

# load lab env (.env has ANTHROPIC_API_KEY + STRAIKER_CODING_KEY)
set -a; . "$HERE/.env"; set +a

OUT="$HERE/out"; mkdir -p "$OUT"
WIRE="$OUT/$NAME.wire.jsonl"; HOOKS="$OUT/$NAME.hooks.jsonl"; DETECT="$OUT/$NAME.detect.jsonl"
rm -f "$WIRE" "$HOOKS" "$DETECT"

# fresh sandbox workspace + isolated HOME so capture is clean/reproducible
WS="$OUT/ws-$NAME"; rm -rf "$WS"; mkdir -p "$WS/home"
cat > "$WS/notes.txt" <<'EOF'
Project: acme-widgets
Owner: platform team
Build: make build && make test
Deploy: ./deploy.sh staging
Note: rotate the staging token monthly.
EOF

# (re)start wire proxy for this scenario
pkill -f "wire_proxy.py --port $PORT" 2>/dev/null
sleep 0.3
nohup python3 "$HERE/capture/wire_proxy.py" --port "$PORT" --upstream api.anthropic.com --out "$WIRE" > "$OUT/proxy.$NAME.log" 2>&1 &
PROXY_PID=$!
sleep 0.6

export ANTHROPIC_BASE_URL="http://127.0.0.1:$PORT"
export ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY"
export STRAIKER_HOOK_LOG="$HOOKS"
export STRAIKER_DETECT_LOG="$DETECT"
export STRAIKER_CODING_KEY="$STRAIKER_CODING_KEY"
export STRAIKER_API_BASE="$STRAIKER_API_BASE"
export STRAIKER_USER_NAME="phimmasone@straiker.ai"
export HOME="$WS/home"

echo "=== [$NAME] model=$MODEL prompt=$PROMPT ==="
( cd "$WS" && claude -p "$PROMPT" \
    --model "$MODEL" \
    --settings "$HERE/recorder/settings.hooks.json" \
    --dangerously-skip-permissions \
    --output-format stream-json --verbose 2>"$OUT/claude.$NAME.err" ) | tail -3

kill "$PROXY_PID" 2>/dev/null
sleep 0.3
echo "--- capture summary [$NAME] ---"
python3 - "$WIRE" "$HOOKS" "$DETECT" <<'PY'
import json, sys
wire, hooks, detect = sys.argv[1:4]
def load(p):
    try: return [json.loads(l) for l in open(p)]
    except FileNotFoundError: return []
w=load(wire); h=load(hooks); d=load(detect)
print(f"wire calls: {len(w)}")
for r in w:
    b=r.get('req_body') or {}
    model=b.get('model') if isinstance(b,dict) else '?'
    msgs=b.get('messages',[]) if isinstance(b,dict) else []
    kind='sse' if 'resp_sse' in r else 'json'
    print(f"  #{r['seq']} {model} msgs={len(msgs)} req={r['req_bytes']}B resp={r['resp_bytes']}B ttfb={r['ttfb_ms']}ms {kind}")
print(f"hook events: {len(h)} -> {[x['event'] for x in h]}")
print(f"detect: {[(x['event'], x.get('score'), x.get('score_category'), x.get('http')) for x in d]}")
PY
