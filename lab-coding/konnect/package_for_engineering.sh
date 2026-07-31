#!/usr/bin/env bash
# Assemble a single, self-contained package for Engineering: the plugin source,
# the docs, the real Kong logs (file-log), the documented prompt->Kong->Straiker
# mapping, and the literal raw wire — from REAL Claude Code traffic only. Zips it.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LAB="$(cd "$HERE/.." && pwd)"
REPO="$(cd "$LAB/.." && pwd)"
PKG="$HERE/out/straiker-coding-engineering-package"
rm -rf "$PKG"; mkdir -p "$PKG"

echo "1. regenerate the engineering export (real Claude Code sessions only)"
python3 "$HERE/export_engineering.py" >/dev/null

echo "2. assemble package"
mkdir -p "$PKG/01-docs" "$PKG/02-kong-logs" "$PKG/03-mapping" "$PKG/04-raw-wire" "$PKG/05-plugin-source"

# docs
cp "$REPO/docs/coding-agent/PLUGIN-GUIDE.md" \
   "$REPO/docs/coding-agent/TEAM-FAQ.md" \
   "$REPO/docs/coding-agent/mapping-analysis.md" \
   "$REPO/docs/coding-agent/latency-analysis.md" \
   "$REPO/docs/coding-agent/claude-code-wire-vs-hooks-micro.md" \
   "$REPO/docs/coding-agent/SUMMARY.md" "$PKG/01-docs/" 2>/dev/null || true

# kong's raw log (real sessions) — the source of truth
cp "$HERE/out/engineering/kong.jsonl" "$PKG/02-kong-logs/kong_file_log.jsonl"

# the documented + structured mapping
cp "$HERE/out/engineering/kong_straiker_mapping.md" "$PKG/03-mapping/"
cp "$HERE/out/engineering/mapping.jsonl" "$PKG/03-mapping/"

# literal raw wire (per model call)
cp -R "$HERE/out/engineering/raw/." "$PKG/04-raw-wire/" 2>/dev/null || true

# plugin source (the enterprise update)
cp "$REPO/kong/plugins/straiker-coding/"*.lua "$PKG/05-plugin-source/"

# stats for the README
read RECORDS SESSIONS ANTH BEDR EVENTS <<<"$(python3 - "$HERE/out/engineering/kong.jsonl" "$HERE/out/engineering/mapping.jsonl" <<'PY'
import json,sys,collections
recs=[json.loads(l) for l in open(sys.argv[1])]
maps=[json.loads(l) for l in open(sys.argv[2])]
sids=set(r['straiker']['session_id'] for r in recs)
be=collections.Counter('bedrock' if '/model' in r.get('request',{}).get('uri','') else 'anthropic' for r in recs)
print(len(recs), len(sids), be['anthropic'], be['bedrock'], len(maps))
PY
)"

cat > "$PKG/README.md" <<EOF
# straiker-coding — Claude Code ↔ Kong ↔ Straiker (engineering package)

Real Claude Code traffic (the CLI, run headless — **not** sub-agents, **not**
constructed requests) through a Kong Konnect data plane with the \`straiker-coding\`
guardrail plugin, exported **from Kong's own file-log**.

**Dataset:** ${RECORDS} real model calls across ${SESSIONS} sessions
(${ANTH} Anthropic + ${BEDR} Bedrock), ${EVENTS} hook events posted to Straiker.

## Contents
- \`01-docs/\` — how it works, exact parsing + event-synthesis table, multi-call
  timing, latency, config, how to configure Kong for Claude Code (PLUGIN-GUIDE.md),
  and the team FAQ.
- \`02-kong-logs/kong_file_log.jsonl\` — **Kong's raw file-log** (source of truth).
  Each line = Kong's log serializer for one model call, incl. \`straiker.request_body\`
  / \`response_body\` (the literal wire), \`straiker.events\` (synthesized hook events +
  the exact payload POSTed to Straiker + the verdict), plus Kong's own request/
  response/latency fields.
- \`03-mapping/\` — \`kong_straiker_mapping.md\` (documented: User Prompt → Raw Kong
  request → plugin synthesis → exact Straiker payload + how → verdict, per session)
  and \`mapping.jsonl\` (one structured record per event).
- \`04-raw-wire/\` — the literal request/response bytes per model call
  (\`<session>_call<N>_request.json\`, \`_response.(sse|json|eventstream.b64)\`).
- \`05-plugin-source/\` — the plugin Lua (coding_agent, sse, eventstream, detect,
  schema, handler).

## The flow
\`\`\`
Claude Code ─HTTP─▶ Kong DP (straiker-coding) ─┬─▶ upstream (Anthropic / Bedrock)
                                               └─▶ Straiker /api/v1/detect  (x-tool: claude-code, HMAC)
\`\`\`
Per model call the plugin parses the raw request/response, synthesizes the Claude
Code hook events (UserPromptSubmit / PreToolUse / PostToolUse), and posts each to
Straiker. See \`01-docs/PLUGIN-GUIDE.md\` §2–§5 for the exact mapping + timing.
EOF

echo "3. zip"
( cd "$HERE/out" && zip -qr "straiker-coding-engineering-package.zip" "straiker-coding-engineering-package" )
echo "PACKAGE: $PKG"
echo "ZIP:     $HERE/out/straiker-coding-engineering-package.zip ($(du -h "$HERE/out/straiker-coding-engineering-package.zip" | cut -f1))"
echo "dataset: ${RECORDS} calls / ${SESSIONS} sessions (${ANTH} anthropic + ${BEDR} bedrock) / ${EVENTS} events"
