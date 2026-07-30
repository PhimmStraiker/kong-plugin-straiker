#!/usr/bin/env bash
# Drive the full scenario matrix (corpus/scenarios.tsv) headless through the wire
# proxy, one isolated session per scenario, capturing wire + hooks + detect.
# Attack scenarios (flag=block) run with STRAIKER_FORCE_BLOCK so the risky tool is
# captured + scored but never executed. Writes to out/corpus/.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
MODEL="${MODEL:-claude-sonnet-4-5-20250929}"
PORT="${PORT:-8788}"
set -a; . "$HERE/.env"; set +a

CO="$HERE/out/corpus"; mkdir -p "$CO"
: > "$CO/manifest.tsv"

n=0
while IFS=$'\t' read -r NAME FLAG PROMPT; do
  [ -z "${NAME:-}" ] && continue
  case "$NAME" in \#*) continue;; esac
  n=$((n+1))
  WIRE="$CO/$NAME.wire.jsonl"; HOOKS="$CO/$NAME.hooks.jsonl"; DETECT="$CO/$NAME.detect.jsonl"
  rm -f "$WIRE" "$HOOKS" "$DETECT"

  WS="$CO/ws-$NAME"; rm -rf "$WS"; mkdir -p "$WS/home"
  cp -R "$HERE/corpus/seed/." "$WS/" 2>/dev/null

  pkill -f "wire_proxy.py --port $PORT" 2>/dev/null; sleep 0.2
  nohup python3 "$HERE/capture/wire_proxy.py" --port "$PORT" --upstream api.anthropic.com --out "$WIRE" > "$CO/proxy.$NAME.log" 2>&1 &
  PROXY_PID=$!; sleep 0.4

  export ANTHROPIC_BASE_URL="http://127.0.0.1:$PORT"
  export ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY"
  export STRAIKER_HOOK_LOG="$HOOKS" STRAIKER_DETECT_LOG="$DETECT"
  export STRAIKER_CODING_KEY="$STRAIKER_CODING_KEY" STRAIKER_API_BASE="$STRAIKER_API_BASE"
  export STRAIKER_USER_NAME="phimmasone@straiker.ai"
  export HOME="$WS/home"
  if [ "$FLAG" = "block" ]; then export STRAIKER_FORCE_BLOCK=1; else unset STRAIKER_FORCE_BLOCK; fi

  echo "[$n] $NAME ($FLAG)"
  ( cd "$WS" && claude -p "$PROMPT" --model "$MODEL" \
      --settings "$HERE/recorder/settings.hooks.json" \
      --dangerously-skip-permissions \
      --output-format stream-json --verbose </dev/null > "$CO/claude.$NAME.out" 2>"$CO/claude.$NAME.err" )
  kill "$PROXY_PID" 2>/dev/null; sleep 0.2

  WC=$(wc -l < "$WIRE" 2>/dev/null | tr -d ' ')
  HC=$(wc -l < "$HOOKS" 2>/dev/null | tr -d ' ')
  printf '%s\t%s\t%s\t%s\n' "$NAME" "$FLAG" "${WC:-0}" "${HC:-0}" >> "$CO/manifest.tsv"
done < "$HERE/corpus/scenarios.tsv"

pkill -f "wire_proxy.py --port $PORT" 2>/dev/null
echo "=== corpus done: $n scenarios ==="
awk -F'\t' '{w+=$3; h+=$4} END{printf "total wire calls: %d   total hook events: %d\n", w, h}' "$CO/manifest.tsv"
