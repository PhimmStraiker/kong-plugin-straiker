#!/usr/bin/env bash
# Promote the plugin to the shared gateway (konggw.dev.straiker.ai).
#
# The QA gate: local checks must pass BEFORE the image is built, and the live gateway is
# smoke-tested AFTER. Internal devs are the QA pool, so the bar is "don't ship something
# obviously broken", not "prove it perfect".
#
#   ./promote.sh --check     what's deployed vs what's on this branch (no changes)
#   ./promote.sh             run the gate, build, deploy, verify
#
# Requires: fresh AWS creds (App Runner + ECR) and KONNECT_PAT.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
REGION="${AWS_REGION:-us-east-1}"
SVC="straiker-shared-kong-gateway"
GW="https://konggw.dev.straiker.ai"
export AWS_PAGER=""
CHECK_ONLY=0; [ "${1:-}" = "--check" ] && CHECK_ONLY=1

step() { printf "\n\033[1m== %s ==\033[0m\n" "$1"; }
fail() { printf "  \033[31mFAIL\033[0m %s\n" "$1"; exit 1; }
ok()   { printf "  \033[32mok\033[0m   %s\n" "$1"; }

LOCAL_VER=$(grep -oE 'VERSION = "[^"]+"' "$REPO/kong/plugins/straiker-coding/handler.lua" | cut -d'"' -f2)
LOCAL_SHA=$(git -C "$REPO" rev-parse --short HEAD)

step "what is deployed vs local"
ARN=$(aws apprunner list-services --region "$REGION" \
        --query "ServiceSummaryList[?ServiceName=='$SVC'].ServiceArn" --output text 2>/dev/null)
if [ -z "$ARN" ]; then
  echo "  (cannot reach App Runner — expired creds?)"
else
  DEPLOYED_IMG=$(aws apprunner describe-service --service-arn "$ARN" --region "$REGION" \
    --query 'Service.SourceConfiguration.ImageRepository.ImageIdentifier' --output text 2>/dev/null)
  echo "  deployed image : ${DEPLOYED_IMG##*:}"
  echo "  local branch   : $LOCAL_SHA  (plugin v$LOCAL_VER)"
  [ "${DEPLOYED_IMG##*:}" = "$LOCAL_SHA" ] && ok "gateway is CURRENT" || echo "  -> gateway is BEHIND this branch"
fi
[ "$CHECK_ONLY" = "1" ] && exit 0

# ---------------------------------------------------------------- local QA gate
step "1/5  working tree is committed"
[ -z "$(git -C "$REPO" status --porcelain)" ] || fail "uncommitted changes — commit first so the image tag matches the code"
ok "clean at $LOCAL_SHA"

step "2/5  lua syntax"
for f in "$REPO"/kong/plugins/straiker-coding/*.lua; do
  luac -p "$f" || fail "syntax error in $f"
done
ok "all modules parse"

step "3/5  golden regression (the real gate)"
"$REPO/spec/run.sh" >/tmp/promote_spec.log 2>&1 || { tail -20 /tmp/promote_spec.log; fail "goldens differ — intended? re-bless, else fix"; }
ok "$(tail -2 /tmp/promote_spec.log | head -1)"

step "3a/5  behavioural QA (asserts each fix actually behaves)"
"$REPO/lab-coding/parity/run_lua.sh" "$REPO/spec/qa.lua" >/tmp/promote_qa.log 2>&1 \
  || { grep -E "FAIL|QA RED" /tmp/promote_qa.log | head -15; fail "behavioural QA failed"; }
ok "$(grep -oE "pass=[0-9]+ +fail=[0-9]+" /tmp/promote_qa.log | tail -1)"

step "3b/5  preflight: plugins enabled on the data plane"
# Kong REJECTS an entire config batch containing a plugin that is not in KONG_PLUGINS,
# and then silently keeps serving its last-good config. That looks exactly like a code
# bug. Catch the ordering mistake here instead.
ENABLED=$(grep -oE '"KONG_PLUGINS":"[^"]*"' "$HERE/apprunner/deploy.sh" | cut -d'"' -f4)
for d in "$REPO"/kong/plugins/*/; do
  pname=$(basename "$d")
  case ",$ENABLED," in *",$pname,"*) ;; *) fail "plugin '$pname' exists but is NOT in KONG_PLUGINS ($ENABLED) — Kong would reject the config" ;; esac
done
ok "all local plugins listed in KONG_PLUGINS: $ENABLED"

step "4/5  build + deploy"
"$HERE/apprunner/deploy.sh" >/tmp/promote_deploy.log 2>&1 || { tail -25 /tmp/promote_deploy.log; fail "deploy failed"; }
ok "image pushed and service updated"

ARN=$(aws apprunner list-services --region "$REGION" --query "ServiceSummaryList[?ServiceName=='$SVC'].ServiceArn" --output text)
printf "  waiting for RUNNING"
until s=$(aws apprunner describe-service --service-arn "$ARN" --region "$REGION" --query 'Service.Status' --output text 2>/dev/null); [ "$s" != "OPERATION_IN_PROGRESS" ]; do printf "."; sleep 15; done
echo " -> $s"
[ "$s" = "RUNNING" ] || fail "service is $s (check App Runner logs)"

# ---------------------------------------------------------------- post-deploy verify
step "5/5  verify the LIVE gateway"
NOKEY=$(curl -m 25 -s "$GW/v1/messages" -X POST -H 'content-type: application/json' -d '{}')
echo "$NOKEY" | grep -q "No API key found" && ok "key-auth rejects anonymous" || fail "key-auth not enforcing: $NOKEY"

if [ -n "${KONGGW_KEY:-}" ]; then
  WITH=$(curl -m 25 -s "$GW/v1/messages" -X POST -H 'content-type: application/json' -H "apikey: $KONGGW_KEY" -d '{}')
  echo "$WITH" | grep -q "x-api-key header is required" \
    && ok "valid key forwards upstream" || fail "forwarding broken: $WITH"
  if command -v claude >/dev/null; then
    R=$(ANTHROPIC_BASE_URL="$GW" ANTHROPIC_CUSTOM_HEADERS="apikey: $KONGGW_KEY" \
        claude -p "reply with exactly: PROMOTE-OK" </dev/null 2>/dev/null)
    [ "$R" = "PROMOTE-OK" ] && ok "real Claude Code turn succeeded" || fail "live turn failed: '$R'"
  fi
else
  echo "  (set KONGGW_KEY to also run the authenticated + real-Claude checks)"
fi

printf "\n\033[32mPROMOTED\033[0m  %s  ->  %s  (plugin v%s)\n" "$LOCAL_SHA" "$GW" "$LOCAL_VER"
