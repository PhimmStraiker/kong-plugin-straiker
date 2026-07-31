#!/usr/bin/env bash
# Drive REAL Claude Code prompts that use an MCP server (konnect/mcp/tasks_server.py)
# through Kong, so the plugin captures mcp__<server>__<tool> calls. Guardrails +
# file-log on. Concurrency-limited.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LAB="$(cd "$HERE/.." && pwd)"
set -a; . "$LAB/.env"; set +a
MODEL="${MODEL:-claude-sonnet-4-5-20250929}"
CONC="${CONC:-4}"
MCPCFG="$HERE/mcp/mcp-config.json"

PROMPTS=(
  "use the tasks MCP tool to add a task 'review the PR' with high priority, then list all tasks"
  "add a task to rotate the staging token using the tasks tool, priority high"
  "list all current tasks using the tasks MCP server and summarize them"
  "use the tasks tool to get the project config for tokenusage and report it"
  "add three tasks via the tasks tool: deploy, run tests, monitor — then list them"
  "get the deployment config for the 'staging' project using the MCP tool"
  "add a task 'patch CVE-1234' and then show me the full task list"
  "use the tasks MCP server to add 'call the customer wednesday' as a normal task"
  "list the tasks, then add any that are missing for a release checklist"
  "get project config for 'tokenusage' and add a task to bump its quota"
  "add a high priority task 'ship kong plugin' and confirm it was added"
  "using the tasks tool, list tasks and tell me which are high priority"
)

OUT="$HERE/out"; WSROOT="$OUT/mcp-vol-ws"; rm -rf "$WSROOT"; mkdir -p "$WSROOT"
run_one() {
  local i="$1" prompt="$2"
  local ws="$WSROOT/m$i"; mkdir -p "$ws/home"; cp -R "$LAB/corpus/seed/." "$ws/" 2>/dev/null
  printf '{ "apiKeyHelper": "sh -c '"'"'echo $ANTHROPIC_API_KEY'"'"'" }\n' > "$ws/settings.json"
  ( cd "$ws" && HOME="$ws/home" ANTHROPIC_BASE_URL="http://localhost:8000" \
      claude -p "$prompt" --model "$MODEL" --settings "$ws/settings.json" \
      --mcp-config "$MCPCFG" --strict-mcp-config \
      --dangerously-skip-permissions </dev/null >/dev/null 2>"$ws/err.txt" )
  echo "  [mcp $i] done: ${prompt:0:50}"
}
echo "=== driving ${#PROMPTS[@]} REAL MCP Claude Code prompts through Kong (conc=$CONC) ==="
i=0
for p in "${PROMPTS[@]}"; do
  run_one "$i" "$p" &
  i=$((i+1))
  while [ "$(jobs -r | wc -l | tr -d ' ')" -ge "$CONC" ]; do sleep 0.5; done
done
wait
echo "=== ${#PROMPTS[@]} MCP sessions complete ==="
