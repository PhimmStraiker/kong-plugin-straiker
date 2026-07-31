# Raw Kong capture — "what Kong sees" for one prompt

Export the literal wire — every model call one Claude Code prompt spawns, exactly
as the Kong data plane receives (request) and returns (response) it, grouped by
session.

## How it works

The `straiker-coding` plugin, when a request carries the header
`X-Straiker-Capture`, appends the raw request and raw response bytes to
`/straiker-capture/<session_id>.jsonl` (a mounted host dir). Records are tagged
with a per-call id (`rid`) stashed in `kong.ctx` so request↔response pair exactly
even though Claude Code fires the title-gen call asynchronously (and Kong's
`ngx.var.request_id` differs between the access and buffered-response phases).

`konnect/export_capture.py` turns one session file into a readable export plus
the literal raw bodies as files.

## Capture a session

```bash
# DP is mounted with a capture dir (lab-coding/konnect/run_dp.sh); then drive a
# real Claude Code prompt through it with the capture header injected:
export ANTHROPIC_BASE_URL=http://localhost:8000
export ANTHROPIC_CUSTOM_HEADERS="X-Straiker-Capture: 1"
claude -p "read config.yaml and tell me the team_b quota" --dangerously-skip-permissions

python3 konnect/export_capture.py <session_id>   # -> konnect/out/export/<session>/
```

## What one prompt looks like on the wire

Prompt: *"read config.yaml and tell me the team_b quota"* → **3 model calls** Kong saw:

| Call | Kind | Request | System | Tools | Response |
|---|---|---|---|---|---|
| 1 | title-gen (Haiku utility) | 2.3 KB | 1.5 KB | 0 | `{"title":"Check team_b quota in config"}` |
| 2 | main turn | **137.5 KB** | 29.4 KB | 22 | SSE `tool_use: Read`, stop=`tool_use` |
| 3 | follow-up (tool_result) | **138.8 KB** | 29.4 KB | 22 | SSE "The team_b quota is 2500", stop=`end_turn` |

The raw main-turn request top-level shape: `{model, system[3 blocks], tools[22],
messages[user: 4 text blocks — 3 <system-reminder> + the prompt], metadata,
max_tokens, thinking, context_management, stream:true}`. This is the "verbose
chatter" — the real prompt is a few bytes inside a 137 KB request.

## Export layout (per session)

```
konnect/out/export/<session>/
  summary.md                          readable: prompt -> every model call
  call_01_request.json                literal raw request Kong received
  call_01_response.sse                literal raw response Kong returned (SSE)
  call_02_request.json  … call_NN…
  session.jsonl                       the raw capture (request+response records)
```

Anthropic responses are SSE (`.sse`); Bedrock `/invoke` is JSON (`.json`);
Bedrock `/invoke-with-response-stream` is the binary `vnd.amazon.eventstream`
(stored base64, decoded in `summary.md`). Two worked examples are in
`konnect/out/export/` (an Anthropic Claude Code session and a Bedrock session).

Captures are gitignored (they contain full request bodies); the plugin capture
code and `export_capture.py` are committed.
