# `straiker-coding` — how it works, how it parses Claude Code, and how to configure it

Enterprise reference for the Kong plugin that puts Straiker guardrails on Claude
Code traffic. Everything here is validated against **real** Claude Code sessions
through Kong (Konnect data plane) — 600+ model calls across Anthropic and Bedrock,
exported from Kong's own `file-log` (`docs/coding-agent/` + `lab-coding/konnect/`).

---

## 1. What it does

Claude Code talks to the model over the wire (Anthropic `/v1/messages` or Bedrock
`/model/{id}/invoke[-with-response-stream]`). The plugin sits inline on the Kong
route, and **for every model call it reconstructs the Claude Code hook events**
(`UserPromptSubmit` / `PreToolUse` / `PostToolUse`) from the raw request/response
and posts each to Straiker `/api/v1/detect` with header `x-tool: claude-code` —
the *same* endpoint the native Claude Code enforcement hooks use. So the gateway
gets hook-parity guardrails with no endpoint hook installed.

```
Claude Code ─HTTP─▶ Kong DP  (straiker-coding plugin) ─┬─▶ upstream (Anthropic / Bedrock)
                                                        └─▶ Straiker /api/v1/detect  (x-tool: claude-code, HMAC-signed)
```

---

## 2. The Claude Code multi-call reality — **when do the hook events occur?**

**One user prompt is not one model call.** Claude Code fans a single prompt into
several HTTP calls, and the hook events are distributed across them. Here is a
**real 4-call session** captured from Kong (`session c2e3387b`, prompt *"read
utils.py and list every function with a one-line description"*):

| Model call | Model | Request size | Event on the **request** (access phase) | Event on the **response** (response phase) |
|---|---|---|---|---|
| **1** | Haiku (title-gen) | 2.3 KB, **0 tools** | — | — |
| **2** | Sonnet (main turn) | 137 KB, 22 tools | **UserPromptSubmit** (the prompt) | **PreToolUse** (`Bash`) |
| **3** | Sonnet | 138 KB | **PostToolUse** (`Bash` result) | **PreToolUse** (`Read`) |
| **4** | Sonnet | 139 KB | **PostToolUse** (`Read` result) | — (`stop_reason: end_turn`) |

Read it as a timeline:

- **Call 1 is a utility call** (Claude Code's Haiku title generator — zero tools).
  The plugin **skips it** (no guardrail event). ~23% of all calls are this class.
- **The prompt is scored once**, on the **request** of the first tool-bearing call
  (`UserPromptSubmit`).
- **Every tool the model wants to run** is scored on the **response** of the call
  that produced it (`PreToolUse`) — *before* Claude Code executes it.
- **Every tool result** (the output of a tool that ran) is scored on the
  **request** of the *next* call (`PostToolUse`) — the result is carried back to
  the model as a `tool_result`, and the gateway sees it there.
- **The final call** has no `tool_use` in its response (`stop_reason: end_turn`) —
  the model gave its answer, so no `PreToolUse` fires.

So for a session with N tool round-trips you get: **1 UserPromptSubmit + N
PreToolUse + N PostToolUse**, spread across ~N+2 model calls (title-gen + the main
turn + one follow-up per tool).

---

## 3. Summary table — event synthesis mapping

| Hook event | Where it lives on the wire | Which model call | Phase | What the plugin looks for | Payload POSTed to Straiker |
|---|---|---|---|---|---|
| *(utility / title-gen)* | request with an **empty `tools`** array | call 1 | access | `tools == []` → utility → **skip** | *nothing* |
| **UserPromptSubmit** | **last `user` message → last `text` block** (not a `<system-reminder>`) | first tool-bearing call | access | last message `role==user`; last text block not starting `<system-reminder>`; tools present; not a chatter marker | `{hook_event_name, prompt, session_id, user_name}` |
| **PreToolUse** | assistant **`tool_use`** block in the **response** | every call whose response emits a tool | response | response content block `type==tool_use` → `name` + `input` (assembled from SSE / Bedrock event-stream) | `{hook_event_name, tool_name, tool_input, tool_use_id, session_id, user_name}` |
| **PostToolUse** | **`tool_result`** block in the **next request** | the call after a tool ran | access | last `user` message block `type==tool_result` (matched to the prior `tool_use_id`) | `{hook_event_name, tool_name, tool_response, tool_use_id, session_id, user_name}` |
| *(Stop)* | response `stop_reason==end_turn`, no `tool_use` | last call | response | no `tool_use` → no event (telemetry only) | *nothing* |

Every event also carries `session_id` (so the whole session's turns are grouped
in Straiker) and `user_name` (identity). Straiker returns a verdict per event
(`turn_id`, `score`, `score_category`, `severity`, `action`).

---

## 4. Exactly how the plugin parses (what it looks for)

Parsing is in `kong/plugins/straiker-coding/coding_agent.lua` (pure Lua,
unit-testable) + `sse.lua` (Anthropic SSE) + `eventstream.lua` (Bedrock binary).

1. **Is this Claude Code?** (`is_claude_code`) — the request's `tools[]` contains
   any of `Bash` / `Read` / `Edit` / `TodoWrite`, or the top-level `system`
   mentions "claude code". If not, the plugin passes the request through untouched.

2. **Session id** (`session_id`) — Claude Code puts a JSON *string* in
   `metadata.user_id` = `{"device_id":…, "session_id":"…"}`; the plugin parses out
   `session_id` (it is **constant across every call of the session**). Fallback:
   the `X-Straiker-Session-Id` request header. No session id ⇒ the plugin does not
   score (avoids fragmenting Straiker's per-session trace).

3. **The user prompt** (`UserPromptSubmit`) — walk `messages` backwards to the last
   `role==user` message; from its content take the **last `text` block that is not
   a `<system-reminder>`**. (Claude Code prepends 3 `<system-reminder>` blocks +
   the real prompt.) In CVS's flattened single-string form, the plugin strips the
   `<system-reminder>` / `<command-*>` scaffolding and takes the trailing text.

4. **Chatter filter** — a call with **zero tools** is a Claude Code utility call
   (title generation, "suggestion mode", conversation recap) whose "prompt" is
   scaffolding, not user intent; it is dropped before `UserPromptSubmit`. This is
   what prevents the false-positive detections gateways see today. (A short,
   specific marker list catches the rare tool-bearing utility call.)

5. **Tool calls** (`PreToolUse`) — the model's response is reassembled
   (`content_block_start{type:tool_use}` + `input_json_delta…` + `content_block_stop`)
   into `{id, name, input}` per tool. `input` is the tool arguments verbatim
   (e.g. `Bash {command:"grep -rn token ."}`, `Read {file_path:"…"}`).

6. **Tool results** (`PostToolUse`) — the *next* request carries the tool output as
   a `tool_result` block in the last user message, matched to its `tool_use_id`.
   The plugin extracts the output text (the indirect-prompt-injection surface).

7. **Dedup** — the agentic loop **resends the whole transcript every call**, so the
   plugin dedups in a `lua_shared_dict` keyed by `session_id` + event key
   (`prompt:<md5>` / `pre:<tool_use_id>` / `post:<tool_use_id>`) — each event is
   emitted exactly once per session.

8. **Bedrock** — the request is the **identical Anthropic Messages format**
   (parser unchanged). The response is `application/vnd.amazon.eventstream` (binary
   frames); `eventstream.lua` decodes the frames into the same Anthropic
   message-stream events, then the identical assembly runs. Non-streaming Bedrock
   `/invoke` returns plain JSON and is parsed directly. (In real testing the plugin
   handled both: 170 JSON + 77 event-stream Bedrock responses.)

---

## 5. What is sent to Straiker, and how

For each synthesized event the plugin POSTs to `detect_url`
(`https://api.prod.straiker.ai/api/v1/detect`) with:

- header **`x-tool: claude-code`** — routes to the coding-agent pipeline (bypasses
  the standard prompt/response schema; same path as the native hooks).
- header **`Authorization: Bearer <app key>`**.
- headers **`X-Straiker-Webhook-Signature` / `-Timestamp`** — HMAC-SHA256 over
  `{timestamp}.{payload}` keyed by the app key (matches the native handler).
- body = the exact event JSON from the table in §3.

`monitor` mode fires these fire-and-forget (zero added latency). When
`log_serialize` is on, the plugin scores **synchronously** so the real verdict
lands in the Kong log line. `block` mode scores `PreToolUse` / `PostToolUse`
synchronously and, on a `deny`, replaces the tool call before the client runs it.

The exact per-event payload and verdict for **real** traffic are in the exported
Kong log — see §8.

---

## 6. Plugin configuration reference

`kong/plugins/straiker-coding/schema.lua`:

| Field | Default | Meaning |
|---|---|---|
| `api_key` | *(required, encrypted)* | Straiker app detect key |
| `detect_url` | `…/api/v1/detect` | Straiker endpoint. Rejects a `…/webhook` URL (that path does not enforce the coding pipeline). |
| `x_tool` | `claude-code` | Routing header value |
| `mode` | `monitor` | `monitor` (score + surface, never block) or `block` (deny tool calls whose verdict is deny) |
| `chatter_filter` | `true` | Drop zero-tool utility/title-gen calls before `UserPromptSubmit` |
| `session_header` | `X-Straiker-Session-Id` | Fallback session id header (used when `metadata.user_id` is absent, e.g. Bedrock without it) |
| `user_name_header` / `user_name_default` | `X-Straiker-User-Name` / `kong-coding` | Identity resolution |
| `model_override` | — | Force the Console model attribution |
| `sign_payloads` | `true` | HMAC-sign the detect POST |
| `fail_open` | `true` | On a detect transport error: input gate fails open; response side always fails open |
| `timeout_ms` | `5000` | Detect call timeout |
| `log_serialize` | `false` | **Observability:** enrich Kong's log serializer with the raw request/response bodies, the synthesized events, the exact detect payloads, and the real verdict (scored synchronously). Pair with a Kong logging plugin (file-log/http-log) to export exactly what Kong sees. |
| `debug` | `false` | Verbose `kong.log` notices |

The plugin is **fail-open by contract**: all parsing runs under `pcall`; a parser
error passes the traffic through untouched and never 500s the client. In real
testing it passed through upstream Bedrock `403`/`404`s (retired/unsubscribed
models) without incident.

---

## 7. How to configure it in Kong for Claude Code

The plugin needs a Kong route to the LLM, itself, and (for the export) Kong's
`file-log`. Scripts: `lab-coding/konnect/setup_cp.py` (config) +
`run_dp.sh` (data plane). Manual shape:

### 7a. Anthropic (`ANTHROPIC_BASE_URL` → Kong)

```
Service  anthropic-coding  →  url https://api.anthropic.com
Route    /v1/messages      →  protocols [http, https]   (must include http, else Kong 426s an http client)
Plugin   straiker-coding   →  { api_key, mode: monitor, log_serialize: true }
Plugin   file-log          →  { path: /straiker-logs/kong.jsonl, reopen: true }   (the export)
```
Client:
```bash
export ANTHROPIC_BASE_URL="http://<kong-host>:8000"
# auth: the client's own x-api-key / OAuth passes through
claude -p "…"
```
To capture the raw wire in the export, the client also sets nothing extra — the
plugin logs every call. (Injecting `X-Straiker-Session-Id` is optional; Claude
Code already supplies a stable session via `metadata.user_id`.)

### 7b. Bedrock (`CLAUDE_CODE_USE_BEDROCK` → Kong)

```
Service  bedrock-coding  →  url https://bedrock-runtime.<region>.amazonaws.com
Route    /model          →  protocols [http, https]
Plugin   straiker-coding →  { api_key, mode: monitor, log_serialize: true }
Plugin   file-log        →  { path: /straiker-logs/kong.jsonl, reopen: true }
```
Client — the clean path is a **Bedrock API key** (bearer auth, no SigV4 so Kong is
a plain proxy):
```bash
export CLAUDE_CODE_USE_BEDROCK=1
export AWS_BEARER_TOKEN_BEDROCK="<ABSK… bedrock api key>"
export ANTHROPIC_BEDROCK_BASE_URL="http://<kong-host>:8000"
export ANTHROPIC_MODEL="us.anthropic.claude-sonnet-4-5-20250929-v1:0"   # use a model the account is subscribed to
claude -p "…"
```
(Mint the key with `aws iam create-service-specific-credential --user-name <user>
--service-name bedrock.amazonaws.com`; the `ServiceCredentialSecret` is the
bearer.) If the customer signs with SigV4 instead of a bearer key, front the
Bedrock route with Kong's `aws-request-signing` plugin so Kong re-signs — that is
the only "extra Kong configuration" Bedrock needs, and it is a route-level plugin,
not a change to `straiker-coding`.

### Is there extra Kong configuration on the plugin?

No extra config on `straiker-coding` beyond the table in §6. The two Kong-level
additions are operational, not plugin logic: (1) `file-log` to export the log,
and (2) for SigV4 Bedrock only, `aws-request-signing` on the Bedrock route.

---

## 8. What real testing showed (600+ calls, both backends)

Exported from Kong's `file-log` (`lab-coding/konnect/out/engineering/`):

- **612 real model calls** (Anthropic + Bedrock) across **83 sessions**;
  **573 events** posted to Straiker (86 `UserPromptSubmit`, 247 `PreToolUse`,
  240 `PostToolUse`); **every** detect call returned 200, **zero** detect errors.
- Request sizes: min 100 B, **median 137 KB**, max 181 KB — the "verbose chatter"
  is real; the plugin reads past it to the model's actual tool calls.
- ~23% of calls were zero-tool title-gen utility calls — correctly skipped (the
  FP class other gateways score).
- Bedrock exercised both response transports (JSON `/invoke` + binary
  `event-stream`) — both decoded to identical events.
- Robustness: 21 Bedrock `403` (opus-5 not Marketplace-subscribed) + 21 `404`
  (retired opus-4 version) were passed through cleanly — plugin fail-open, no
  crash, upstream error returned to the client.

### The exported artifacts (for Engineering)

- `kong_straiker_mapping.md` — the documented per-call mapping: User Prompt → Raw
  Kong request → plugin synthesis → exact payload sent to Straiker (+ how) →
  verdict, grouped by session.
- `mapping.jsonl` — one structured record per event (573) for tooling.
- `kong.jsonl` — **Kong's raw `file-log`** (source of truth; every field Kong
  serialized incl. `straiker.request_body` / `response_body` / `events` / verdict).
- `raw/<session>_call<N>_request.json` / `_response.(sse|json|eventstream.b64)` —
  the literal bytes Kong received/returned.

Reproduce: `lab-coding/konnect/run_real_volume.sh` (real Claude Code, Anthropic or
`BACKEND=bedrock`) → `export_engineering.py`.
