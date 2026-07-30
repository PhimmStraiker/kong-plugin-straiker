# lab-coding — Claude Code ↔ Kong parity lab

Reproducible lab behind the `straiker-coding` plugin. Captures real Claude Code
traffic, replays it through the plugin parser, and proves the gateway
reconstructs the Straiker hook events at parity. See
`../docs/coding-agent/` for the analysis, latency, micro-deliverable, and summary.

## Layout

- `capture/wire_proxy.py` — byte-exact record-and-forward proxy (Claude Code →
  proxy → Anthropic), teeing request + SSE response to JSONL.
- `capture/mock_detect_deny.py` — controlled `/api/v1/detect` mock for the
  block-mode demo.
- `recorder/hook_recorder.py` + `settings.hooks.json` — native Claude Code hook
  recorder (the parity oracle); posts to the real Straiker app in monitor mode.
- `corpus/scenarios.tsv` + `corpus/seed/` — 39-scenario matrix + seed project.
- `run_corpus.sh` — drive the whole matrix headless, capturing wire + hooks.
- `run_via_kong.sh` — drive Claude Code **through Kong** (the live inline path).
- `parity/` — `lua_cli.lua` replays a captured session through the actual plugin
  parser; `parity_check.py` diffs against the native hooks; `test_eventstream.lua`
  verifies the Bedrock binary-frame decoder on a real capture.
- `kong/` — local Kong 3.14 (docker-compose, DB-less) with the plugin mounted.
- `analyze_corpus.py` — corpus statistics.

## Quick start

```bash
# 1. lab-coding/.env holds STRAIKER_CODING_KEY + ANTHROPIC_API_KEY (gitignored)
# 2. bring up Kong (monitor mode) with the plugin
kong/up.sh monitor

# 3. drive real Claude Code through Kong -> events land in the Straiker Console
./run_via_kong.sh demo "read README.md and summarize it"
docker logs straiker-coding-kong 2>&1 | grep straiker-coding   # synthesized events + detect turn_ids

# 4. build the corpus + prove parity
./run_corpus.sh
python3 parity/parity_check.py
python3 analyze_corpus.py
```

Everything under `out/` (captures, rendered configs with keys, workspaces) is
gitignored — never committed.
