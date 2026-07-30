# Latency analysis: buffered vs streaming enforcement

The `straiker-coding` plugin must inspect the model's response to synthesize
`PreToolUse` events (the tool call the model wants to make). To *block* a tool
call before the client executes it, the plugin has to see the whole `tool_use`
block — which, in the buffered design, means holding the response until it is
complete. This measures what that costs.

## Method

Same request (`claude-haiku-4-5`, `max_tokens: 400`, `stream: true`, a ~300-word
generation) sent 3× two ways:

- **Direct** to `api.anthropic.com` (native streaming).
- **Through Kong** with `straiker-coding` in `monitor` mode (buffered response).

`curl -w` reports `time_starttransfer` (time to first response byte ≈ time to
first token when streaming) and `time_total`.

## Result

| Path | Time to first token (TTFB) | Total time |
|---|---|---|
| Direct (streaming) | **0.53 – 0.69 s** (median ≈ 0.59 s) | 4.10 – 4.37 s |
| Kong (buffered) | **4.09 – 4.61 s** (≈ total) | 4.09 – 4.62 s |

Two separate numbers matter, and they behave very differently:

- **Total latency added by Kong is negligible** — ~50–200 ms for the extra proxy
  hop. The plugin's detect calls in monitor mode run in an `ngx.timer`
  (fire-and-forget), so scoring adds **zero** to the response path.
- **Perceived latency (time-to-first-token) is what buffering destroys.**
  Buffering converts TTFB from "first token" (~0.6 s) into "entire response"
  (~4.1 s) — a **~7× increase, ~3.5 s of dead air** before the developer sees
  anything. On a long generation this is the difference between "instant" and
  "did it hang?".

## Why the buffered design blocks reliably

Once an SSE/event-stream byte is flushed to the client, it cannot be recalled.
To guarantee a denied `tool_use` never reaches the client, the plugin must not
release the response until it has scored the tool call. Full buffering is the
simplest correct way to do that, and it is what ships in `monitor`/`block` v1.

Cost of enforcement in **block** mode: `PreToolUse` scoring is synchronous (the
plugin waits for one `/api/v1/detect` round-trip before releasing the response),
so block mode adds the detect latency (~0.2–0.5 s) on top of the buffered total,
on tool-calling turns only.

## The streaming-hold design (fast-follow, preserves TTFB)

Buffering is heavier than it needs to be: only `tool_use` blocks must be held —
assistant **text** can stream through untouched. The `body_filter`/`log` design
(recoverable from plugin v0.9.0's streaming handler) does exactly that:

1. Stream `content_block_delta` **text** frames straight to the client → TTFB
   returns to ~0.6 s for the visible answer.
2. When a `content_block_start` of `type: tool_use` opens, **hold** its
   `input_json_delta` frames in a per-request buffer instead of forwarding.
3. On `content_block_stop`, score the completed `tool_use`. If allowed, flush the
   held frames; if denied, inject an SSE `error` + `message_stop` and drop the
   tool_use frames — the client never receives a runnable denied tool call.

This preserves streaming for the 90%+ of response bytes that are text while still
giving genuine pre-execution enforcement on the tool call. It is strictly harder
(a stateful chunk-boundary parser; for Bedrock the binary `vnd.amazon.eventstream`
frames must be re-encoded on the way out) and is the recommended v2.

**Recommendation:** ship buffered `monitor`/`block` first (correct, simple,
negligible *total* overhead); follow with the streaming-hold variant to recover
time-to-first-token. The efficacy is identical either way — only the developer's
perceived responsiveness differs.

## Numbers to reuse

- Kong proxy + async scoring overhead on total time: **~50–200 ms**.
- Buffering penalty on time-to-first-token: **~3.5 s** on a 400-token response
  (scales with response length; a 4k-token coding response is far worse).
- Block-mode synchronous detect add: **~0.2–0.5 s** per tool-calling turn.
