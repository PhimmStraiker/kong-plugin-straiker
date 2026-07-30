#!/usr/bin/env bash
# Interactive Claude Code session routed THROUGH Kong so you can drive it by hand
# and watch the plugin synthesize + post guardrail events (see ./watch.sh).
#
#   ./manual.sh            # interactive session in a scratch workspace
#   ./manual.sh "prompt"   # one-shot headless prompt
#
# Monitor mode posts to the real Straiker app "Claude Code through Kong"
# (dapp_E2GkIaZn8AT). Note: buffered mode removes token streaming — responses
# arrive at once. Bring Kong up first with:  kong/up.sh monitor
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
set -a; . "$HERE/.env"; set +a

WS="$HERE/out/manual-ws"; mkdir -p "$WS/home"
[ -e "$WS/README.md" ] || cp -R "$HERE/corpus/seed/." "$WS/" 2>/dev/null
cat > "$WS/settings.json" <<EOF
{ "apiKeyHelper": "sh -c 'echo \$ANTHROPIC_API_KEY'" }
EOF

export ANTHROPIC_BASE_URL="http://localhost:8000"
export ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY"
export HOME="$WS/home"

echo "Kong: $ANTHROPIC_BASE_URL   app: Claude Code through Kong   (watch with: ./watch.sh)"
cd "$WS"
if [ $# -ge 1 ]; then
  claude -p "$1" --settings "$WS/settings.json" --dangerously-skip-permissions </dev/null
else
  claude --settings "$WS/settings.json" --dangerously-skip-permissions
fi
