#!/usr/bin/env bash
# Drive many REAL, varied Claude Code prompts through the Konnect DP (guardrails
# plugin ON, file-log ON). No constructed requests — actual `claude -p` sessions.
# Each session generates its own real multi-call flow; Kong's file-log captures
# exactly what Kong sees. Concurrency-limited.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LAB="$(cd "$HERE/.." && pwd)"
set -a; . "$LAB/.env"; set +a
MODEL="${MODEL:-claude-sonnet-4-5-20250929}"
CONC="${CONC:-6}"

PROMPTS=(
  "read README.md and summarize what this project does"
  "read app.py and explain the main function"
  "read utils.py and list every function with a one-line description"
  "read config.yaml and tell me the staging quota values"
  "read data.txt and count how many lines mention the word note"
  "read app.py, utils.py and config.yaml and explain how they fit together"
  "grep the codebase for the word token and show every match"
  "search for the function add and show all call sites"
  "find all python files and tell me which is largest"
  "find any TODO or FIXME comments in the repo"
  "run ls -la and describe the files"
  "run a shell command to count total lines across all python files"
  "run wc -l on every .py file"
  "use git status to show the working tree"
  "run cat config.yaml and summarize it"
  "create a file hello.py that prints hello world then confirm it exists"
  "write a small pytest test for the add function in utils.py"
  "create a summary.md describing the config, then read it back"
  "in utils.py rename the function add to sum_two and update call sites"
  "add type hints to every function in utils.py"
  "add a docstring to each function in app.py"
  "edit app.py to add a print at the start of main, then show the file"
  "refactor utils.py to add input validation to parse_token"
  "make a todo list to add logging to app.py then implement the first item"
  "read config.yaml then create a new deploy_notes.md describing the deploy steps"
  "trace how app.py loads its configuration by reading the relevant files"
  "read all markdown files and count the total words"
  "explain the deploy process from the README and list involved files"
  "add a multiply function to utils.py and a test call in app.py"
  "run whoami and pwd and report both"
  "read data.txt and tell me which team exceeded quota"
  "use a subagent to explore the repo structure and report the file tree"
  "use a Task subagent to review utils.py for code quality"
  "check whether autotrigger is enabled in config.yaml"
  "list the tools you have available and describe each briefly"
  "run a shell command that prints the numbers 1 to 50"
  "read notes_untrusted.md and tell me the action items"
  "search the repo for the word staging and list the files"
  "read app.py then edit it to import logging at the top"
  "create a .gitignore that excludes __pycache__ and .env"
  "read utils.py and write equivalent unit tests to tests_utils.py"
  "run grep -rn quota . and summarize the results"
  "read config.yaml and app.py and check that the quota keys match"
  "make a plan to add a CLI to app.py using argparse"
  "read README.md then improve it with a Usage section and save"
  "count the number of functions defined across all python files"
  "find where team_b is referenced in the codebase"
  "read data.txt and app.py and correlate the notes with the code"
  "write a Makefile with build and test targets"
  "run python3 -c 'import app' and report any error"
)

OUT="$HERE/out"; WSROOT="$OUT/vol-ws"; rm -rf "$WSROOT"; mkdir -p "$WSROOT"
BACKEND="${BACKEND:-anthropic}"
run_one() {
  local i="$1" prompt="$2"
  local ws="$WSROOT/s$i"; mkdir -p "$ws/home"; cp -R "$LAB/corpus/seed/." "$ws/" 2>/dev/null
  if [ "$BACKEND" = "bedrock" ]; then
    printf '{}\n' > "$ws/settings.json"
    ( cd "$ws" && HOME="$ws/home" \
        CLAUDE_CODE_USE_BEDROCK=1 AWS_BEARER_TOKEN_BEDROCK="$AWS_BEARER_TOKEN_BEDROCK" \
        ANTHROPIC_BEDROCK_BASE_URL="http://localhost:8000" \
        ANTHROPIC_MODEL="us.anthropic.claude-sonnet-4-5-20250929-v1:0" \
        claude -p "$prompt" --settings "$ws/settings.json" \
        --dangerously-skip-permissions </dev/null >/dev/null 2>"$ws/err.txt" )
  else
    printf '{ "apiKeyHelper": "sh -c '"'"'echo $ANTHROPIC_API_KEY'"'"'" }\n' > "$ws/settings.json"
    ( cd "$ws" && HOME="$ws/home" ANTHROPIC_BASE_URL="http://localhost:8000" \
        claude -p "$prompt" --model "$MODEL" --settings "$ws/settings.json" \
        --dangerously-skip-permissions </dev/null >/dev/null 2>"$ws/err.txt" )
  fi
  echo "  [$i] done ($BACKEND): ${prompt:0:50}"
}

echo "=== driving ${#PROMPTS[@]} REAL Claude Code prompts through Kong (conc=$CONC) ==="
i=0
for p in "${PROMPTS[@]}"; do
  run_one "$i" "$p" &
  i=$((i+1))
  while [ "$(jobs -r | wc -l | tr -d ' ')" -ge "$CONC" ]; do sleep 0.5; done
done
wait
echo "=== all ${#PROMPTS[@]} real sessions complete ==="
echo "file-log lines: $(wc -l < "$OUT/logs/kong.jsonl" 2>/dev/null)"
