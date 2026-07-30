#!/usr/bin/env bash
# Drive a headless Claude Code scenario THROUGH Kong (the plugin synthesizes hook
# events and posts them to the Straiker Console). No capture proxy, no hook
# recorder — this exercises the real inline path: Claude Code -> Kong -> Anthropic.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
NAME="${1:?name}"; PROMPT="${2:?prompt}"; MODEL="${3:-claude-sonnet-4-5-20250929}"
set -a; . "$HERE/.env"; set +a

WS="$HERE/out/kong-ws-$NAME"; rm -rf "$WS"; mkdir -p "$WS/home"
cp -R "$HERE/corpus/seed/." "$WS/" 2>/dev/null

export ANTHROPIC_BASE_URL="http://localhost:8000"
export ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY"
export HOME="$WS/home"

# minimal settings: just apiKeyHelper so headless auth works (NO hooks — Kong is
# the enforcement point here, not the endpoint).
cat > "$WS/settings.json" <<EOF
{ "apiKeyHelper": "sh -c 'echo \$ANTHROPIC_API_KEY'" }
EOF

echo "=== [$NAME] via Kong: $PROMPT ==="
( cd "$WS" && claude -p "$PROMPT" --model "$MODEL" \
    --settings "$WS/settings.json" \
    --dangerously-skip-permissions \
    --output-format stream-json --verbose > "$HERE/out/kong.$NAME.out" 2>"$HERE/out/kong.$NAME.err" ) | tail -2
echo "--- result ---"
python3 -c "import json,sys
for l in open('$HERE/out/kong.$NAME.out'):
    try: d=json.loads(l)
    except: continue
    if d.get('type')=='result': print('result:', (d.get('result') or '')[:200])
" 2>/dev/null
