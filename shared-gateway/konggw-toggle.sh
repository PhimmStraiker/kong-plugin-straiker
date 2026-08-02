# Straiker shared Claude Code gateway — teammate toggle.
#   1) get your key from whoever runs the gateway (03_provision_user.py add you@straiker.ai)
#   2) export STRAIKER_KEY='<your key>'
#   3) source konggw-toggle.sh   then:  konggw-on / konggw-off / konggw-status
#
# Your normal `claude` login is untouched — this only redirects the base URL to the
# shared gateway, which applies Straiker guardrails and forwards to Anthropic/Bedrock.
# Your identity in the Straiker Console comes from your key (no extra setup).

KONGGW_URL="${KONGGW_URL:-https://yamxf549ty.us-east-1.awsapprunner.com}"

konggw-on() {          # Claude Code -> shared gateway -> Anthropic (guardrails ON)
  if [ -z "${STRAIKER_KEY:-}" ]; then echo "set STRAIKER_KEY='<your key>' first"; return 1; fi
  unset CLAUDE_CODE_USE_BEDROCK AWS_BEARER_TOKEN_BEDROCK ANTHROPIC_BEDROCK_BASE_URL
  export ANTHROPIC_BASE_URL="$KONGGW_URL"
  export ANTHROPIC_CUSTOM_HEADERS="apikey: $STRAIKER_KEY"
  echo "Claude Code → $KONGGW_URL → Anthropic   [Straiker guardrails ON]"
}

konggw-bedrock-on() {  # Claude Code -> shared gateway -> Bedrock (needs your own Bedrock token)
  if [ -z "${STRAIKER_KEY:-}" ]; then echo "set STRAIKER_KEY first"; return 1; fi
  if [ -z "${AWS_BEARER_TOKEN_BEDROCK:-}" ]; then echo "set AWS_BEARER_TOKEN_BEDROCK (your Bedrock API key) first"; return 1; fi
  unset ANTHROPIC_BASE_URL
  export CLAUDE_CODE_USE_BEDROCK=1
  export ANTHROPIC_BEDROCK_BASE_URL="$KONGGW_URL"
  export ANTHROPIC_CUSTOM_HEADERS="apikey: $STRAIKER_KEY"
  export ANTHROPIC_MODEL="${ANTHROPIC_MODEL:-us.anthropic.claude-sonnet-4-5-20250929-v1:0}"
  echo "Claude Code → $KONGGW_URL → Bedrock   [Straiker guardrails ON]"
}

konggw-off() {         # back to direct (no gateway, no guardrails)
  unset ANTHROPIC_BASE_URL ANTHROPIC_CUSTOM_HEADERS CLAUDE_CODE_USE_BEDROCK AWS_BEARER_TOKEN_BEDROCK ANTHROPIC_BEDROCK_BASE_URL ANTHROPIC_MODEL
  echo "Claude Code → direct (guardrails OFF)"
}

konggw-status() {
  echo "ANTHROPIC_BASE_URL=${ANTHROPIC_BASE_URL:-<unset>}  BEDROCK=${CLAUDE_CODE_USE_BEDROCK:-0}  key=$([ -n "${STRAIKER_KEY:-}" ] && echo set || echo MISSING)"
}
