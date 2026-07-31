# Claude Code <-> Kong (Straiker guardrails) toggle.
# Source this in your shell:   source lab-coding/konnect/claude-kong-toggle.sh
# Then use:  kong-on / kong-off / kong-status   (Anthropic)
#            kong-bedrock-on / kong-off         (Bedrock)
# Your normal `claude` login (OAuth) is preserved — this only redirects the
# base URL, which Kong forwards to the real upstream after guardrailing.

KONG_URL="${KONG_URL:-http://localhost:8000}"
# Identity shown in the Straiker Console for your turns. Claude Code doesn't send your
# real identity on the wire, so we inject it as a header the plugin reads. Override with
# STRAIKER_USER (e.g. your email, or $USER for OS-username parity with the native hooks).
STRAIKER_USER="${STRAIKER_USER:-phimmasone@straiker.ai}"

kong-on() {          # route Claude Code -> Kong -> Anthropic (guardrails ON)
  unset CLAUDE_CODE_USE_BEDROCK AWS_BEARER_TOKEN_BEDROCK ANTHROPIC_BEDROCK_BASE_URL
  export ANTHROPIC_BASE_URL="$KONG_URL"
  export ANTHROPIC_CUSTOM_HEADERS="X-Straiker-User-Name: $STRAIKER_USER"
  echo "Claude Code → Kong ($KONG_URL) → Anthropic   [Straiker guardrails ON]"
  echo "  identity: $STRAIKER_USER   (buffered: responses arrive complete, not token-streamed)"
}

kong-bedrock-on() {  # route Claude Code -> Kong -> Bedrock (guardrails ON)
  if [ -z "${AWS_BEARER_TOKEN_BEDROCK:-}" ]; then
    echo "set AWS_BEARER_TOKEN_BEDROCK to a Bedrock API key first (see PLUGIN-GUIDE.md §7b)"; return 1
  fi
  unset ANTHROPIC_BASE_URL
  export CLAUDE_CODE_USE_BEDROCK=1
  export ANTHROPIC_BEDROCK_BASE_URL="$KONG_URL"
  export ANTHROPIC_CUSTOM_HEADERS="X-Straiker-User-Name: $STRAIKER_USER"
  export ANTHROPIC_MODEL="${ANTHROPIC_MODEL:-us.anthropic.claude-sonnet-4-5-20250929-v1:0}"
  echo "Claude Code → Kong ($KONG_URL) → Bedrock   [Straiker guardrails ON]   identity: $STRAIKER_USER"
}

kong-off() {         # back to normal (direct, no Kong, no guardrails)
  unset ANTHROPIC_BASE_URL CLAUDE_CODE_USE_BEDROCK AWS_BEARER_TOKEN_BEDROCK ANTHROPIC_BEDROCK_BASE_URL ANTHROPIC_MODEL ANTHROPIC_CUSTOM_HEADERS
  echo "Claude Code → direct (guardrails OFF)"
}

kong-status() {
  echo "ANTHROPIC_BASE_URL=${ANTHROPIC_BASE_URL:-<unset>}  USE_BEDROCK=${CLAUDE_CODE_USE_BEDROCK:-0}  BEDROCK_BASE_URL=${ANTHROPIC_BEDROCK_BASE_URL:-<unset>}"
  if [ -n "${ANTHROPIC_BASE_URL:-}${ANTHROPIC_BEDROCK_BASE_URL:-}" ]; then echo "  -> routed through Kong (guardrails ON)"; else echo "  -> direct"; fi
}
