#!/usr/bin/env bash
# Golden regression harness for the straiker-coding parser.
#
# Replays TRACKED wire fixtures through the REAL plugin modules (offline, no Kong,
# no network) and diffs the synthesized hook events against checked-in goldens.
#
#   ./spec/run.sh            # verify against goldens  (exit 1 on any diff)
#   ./spec/run.sh --bless    # regenerate goldens (only when a change is INTENDED)
#
# This is the gate for every refactor step: a pure move must leave the goldens
# byte-identical. Fixtures are gzipped real Claude Code traffic; goldens are the
# normalized hook events the plugin produces from them.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
FIX="$HERE/fixtures/claude-code"
GOLD="$HERE/golden"
RUNNER="$REPO/lab-coding/parity/run_lua.sh"     # sets PLUGIN_REPO + luarocks cpath
BLESS=0; [ "${1:-}" = "--bless" ] && BLESS=1
mkdir -p "$GOLD"

command -v lua >/dev/null || { echo "lua not found"; exit 1; }
[ -x "$RUNNER" ] || { echo "missing replay harness: $RUNNER"; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0; blessed=0

for wz in "$FIX"/*.wire.jsonl.gz; do
  [ -e "$wz" ] || { echo "no fixtures in $FIX"; exit 1; }
  name="$(basename "$wz" .wire.jsonl.gz)"
  gunzip -c "$wz" > "$TMP/$name.wire.jsonl"

  # replay through the real modules; normalize volatile fields so goldens are stable
  if ! "$RUNNER" "$TMP/$name.wire.jsonl" > "$TMP/$name.raw" 2>"$TMP/$name.err"; then
    echo "  ERROR  $name  (replay failed)"; sed 's/^/         /' "$TMP/$name.err" | head -3; fail=$((fail+1)); continue
  fi
  python3 - "$TMP/$name.raw" > "$TMP/$name.out" <<'PY'
import json,sys,re
# stable, comparable projection of each synthesized event
for line in open(sys.argv[1]):
    line=line.strip()
    if not line: continue
    try: e=json.loads(line)
    except Exception: print(line); continue
    if isinstance(e,dict):
        e.pop("session_id",None); e.pop("user_name",None); e.pop("timestamp",None)
        if isinstance(e.get("prompt"),str): e["prompt"]=e["prompt"][:300]
        if isinstance(e.get("app_response"),str): e["app_response"]=e["app_response"][:300]
    print(json.dumps(e,sort_keys=True))
PY

  g="$GOLD/$name.expected.jsonl"
  if [ "$BLESS" = "1" ] || [ ! -f "$g" ]; then
    cp "$TMP/$name.out" "$g"; echo "  BLESS  $name ($(wc -l < "$g" | tr -d ' ') events)"; blessed=$((blessed+1))
  elif diff -q "$g" "$TMP/$name.out" >/dev/null; then
    pass=$((pass+1))
  else
    echo "  DIFF   $name"; diff "$g" "$TMP/$name.out" | head -12 | sed 's/^/         /'; fail=$((fail+1))
  fi
done

echo "--------------------------------------------"
echo "pass=$pass  fail=$fail  blessed=$blessed"
[ "$fail" -gt 0 ] && { echo "REGRESSION: goldens differ. If intended, re-run with --bless."; exit 1; }
echo "OK"
