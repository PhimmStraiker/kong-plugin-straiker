#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LAB="$(cd "$HERE/.." && pwd)"
rm -f "$LAB/out/logs/kong.jsonl"; touch "$LAB/out/logs/kong.jsonl"; chmod 666 "$LAB/out/logs/kong.jsonl"
echo "### 1/3 Anthropic regular (50, v0.13.0 Stop)"; "$HERE/run_real_volume.sh"
echo "### 2/3 MCP (12)"; "$HERE/run_mcp_volume.sh"
echo "### 3/3 Bedrock (50)"; BACKEND=bedrock CONC=5 AWS_BEARER_TOKEN_BEDROCK="$(cat /tmp/bedrock_key.txt)" "$HERE/run_real_volume.sh"
echo "DONE_MASTER: $(wc -l < "$LAB/out/logs/kong.jsonl") kong log lines"
