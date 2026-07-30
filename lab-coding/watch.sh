#!/usr/bin/env bash
# Live tail of the synthesized hook events the plugin posts, one clean line each:
#   <event> · <tool> · <session> · detect <status>
# Run this in one terminal while you drive Claude Code through Kong in another.
docker logs -f straiker-coding-kong 2>&1 \
  | grep --line-buffered "straiker-coding" \
  | sed -u -E \
      -e 's/.*access sid=([^ ]+).*events=\[([^]]*)\].*/EVENT  \2   (session \1)/' \
      -e 's/.*response sid=([^ ]+).*tool_uses=([0-9]+).*/RESPONSE  tool_uses=\2   (session \1)/' \
      -e 's/.*(UserPromptSubmit|PreToolUse|PostToolUse) detect ([0-9]+).*"turn_id":"([^"]+)".*/POSTED  \1  ->  detect \2  turn \3/' \
      -e 's/.*BLOCK (PreToolUse|PostToolUse) ([^ ]+).*/BLOCKED  \1  \2/' \
  | grep --line-buffered -E "^EVENT|^POSTED|^BLOCKED|^RESPONSE"
