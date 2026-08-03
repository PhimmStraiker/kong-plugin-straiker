#!/usr/bin/env bash
# Live QA against the deployed shared gateway. Offline suites prove the parser; this
# proves the deployed thing actually serves, enforces, and streams.
#   KONGGW_KEY=... ./live_qa.sh
set -uo pipefail
GW="${GW:-https://konggw.dev.straiker.ai}"
KEY="${KONGGW_KEY:?set KONGGW_KEY}"
pass=0; fail=0
ok(){ printf "  \033[32mPASS\033[0m %s\n" "$1"; pass=$((pass+1)); }
no(){ printf "  \033[31mFAIL\033[0m %s -> %s\n" "$1" "$2"; fail=$((fail+1)); }

echo "== auth =="
B=$(curl -m 25 -s "$GW/v1/messages" -X POST -H 'content-type: application/json' -d '{}')
echo "$B" | grep -q "No API key found" && ok "anonymous rejected by key-auth" || no "anonymous rejected" "$B"
B=$(curl -m 25 -s "$GW/v1/messages" -X POST -H 'content-type: application/json' -H "apikey: bogus-key" -d '{}')
echo "$B" | grep -qi "unauthorized" && ok "invalid key rejected" || no "invalid key rejected" "$B"
B=$(curl -m 25 -s "$GW/v1/messages" -X POST -H 'content-type: application/json' -H "apikey: $KEY" -d '{}')
echo "$B" | grep -q "x-api-key header is required" && ok "valid key forwards upstream" || no "valid key forwards" "$B"

echo "== real Claude Code turns =="
R=$(ANTHROPIC_BASE_URL="$GW" ANTHROPIC_CUSTOM_HEADERS="apikey: $KEY" \
    claude -p "reply with exactly: LIVE-OK" </dev/null 2>/dev/null)
[ "$R" = "LIVE-OK" ] && ok "simple turn" || no "simple turn" "$R"

T=$(mktemp -d); echo "quota: 1000" > "$T/config.yaml"
R=$(cd "$T" && ANTHROPIC_BASE_URL="$GW" ANTHROPIC_CUSTOM_HEADERS="apikey: $KEY" \
    claude -p "read config.yaml and state the quota" --dangerously-skip-permissions </dev/null 2>/dev/null)
echo "$R" | grep -q "1000" && ok "tool-using turn (Read)" || no "tool-using turn" "$R"
rm -rf "$T"

echo "== streaming preserved (the SE-facing property) =="
TTFT=$(python3 - "$GW" "$KEY" <<'PY'
import sys,time,json,urllib.request
gw,key=sys.argv[1],sys.argv[2]
import os
ak=os.environ.get("ANTHROPIC_KEY") or os.environ.get("ANTHROPIC_API_KEY") or ""
body=json.dumps({"model":"claude-sonnet-4-5-20250929","max_tokens":400,"stream":True,
 "messages":[{"role":"user","content":"Explain TCP congestion control in 300 words."}]})
h={"content-type":"application/json","x-api-key":ak,"anthropic-version":"2023-06-01","apikey":key}
t0=time.time(); first=None
try:
    r=urllib.request.Request(gw+"/v1/messages",data=body.encode(),headers=h,method="POST")
    with urllib.request.urlopen(r,timeout=120) as x:
        for line in x:
            if line.startswith(b"data:") and b"text_delta" in line and first is None:
                first=time.time()-t0; break
    print(f"{first:.2f}" if first else "none")
except Exception as e: print("err")
PY
)
case "$TTFT" in
  err|none) no "time-to-first-token" "$TTFT" ;;
  *) awk -v t="$TTFT" 'BEGIN{exit !(t<5)}' \
       && ok "streaming: first token in ${TTFT}s" \
       || no "streaming (expected <5s)" "${TTFT}s" ;;
esac

echo "== agent routes reachable + gated =="
for a in codex cursor opencode copilot; do
  p="v1/chat/completions"; [ "$a" = "codex" ] && p="v1/responses"
  n=$(curl -m 20 -s -o /dev/null -w '%{http_code}' -X POST "$GW/$a/$p" -H 'content-type: application/json' -d '{}')
  w=$(curl -m 20 -s -X POST "$GW/$a/$p" -H 'content-type: application/json' -H "apikey: $KEY" -d '{}')
  if [ "$n" = "401" ] && echo "$w" | grep -qi "api key\|authentication"; then ok "/$a gated + forwarding"
  else no "/$a" "nokey=$n with=$(echo "$w" | head -c 60)"; fi
done

printf "\n%s  pass=%d fail=%d\n" "$([ $fail -eq 0 ] && printf '\033[32mLIVE QA GREEN\033[0m' || printf '\033[31mLIVE QA RED\033[0m')" "$pass" "$fail"
exit $([ $fail -eq 0 ] && echo 0 || echo 1)
