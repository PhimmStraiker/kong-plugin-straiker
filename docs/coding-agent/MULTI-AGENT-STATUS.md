# Multi-agent support — verified status (2026-08-02)

Everything below was measured against **real captured traffic** from the actual CLIs run
through a local capture server, and the **real plugin parser** (`coding_agent.lua`) — not
inferred from docs.

## Routing: works today for all agents

Per-agent routes on the shared gateway (`04_add_agent_routes.py`), each with its **own
Straiker detect key** so events land in that agent's own collection — never mixed into
Claude Code's:

| Agent | Client base URL | Upstream | Verified |
|---|---|---|---|
| Claude Code | `https://konggw.dev.straiker.ai` | api.anthropic.com | ✅ real turn, guardrailed |
| Codex | `https://konggw.dev.straiker.ai/codex/v1` | api.openai.com `/v1/responses` | ✅ **real `codex exec` returned through the gateway** |
| Cursor | `https://konggw.dev.straiker.ai/cursor/v1` | api.openai.com `/v1/chat/completions` | ✅ route + key-auth (GUI app, not headless-testable) |
| OpenCode | `https://konggw.dev.straiker.ai/opencode/v1` | api.openai.com `/v1/chat/completions` | ✅ route + key-auth; real body captured |
| Copilot | `https://konggw.dev.straiker.ai/copilot/v1` | api.openai.com `/v1/chat/completions` | ✅ route + key-auth |

All routes: no key → Kong 401; valid key → forwarded (upstream's own auth error returned).

## Guardrails: Claude Code only. The others produce ZERO events.

Running the real parser against real bodies:

| | Claude Code | Codex (Responses) | OpenCode/Cursor (Chat) |
|---|---|---|---|
| `is_claude_code` | ✅ true | ❌ **false** | ❌ **false** |
| `session_id` | ✅ from `metadata.user_id` | ❌ **nil** | ❌ **nil** |
| `user_prompt` | ✅ | ❌ **nil** | ⚠️ "list files" (accidental — both use `messages[]`) |
| tool_results | ✅ | ❌ wrong shape | ❌ wrong shape |
| **Events emitted** | ✅ | **0** | **0** |

Two independent gates drop non-Claude traffic: `is_claude_code` returns false, and even if
it passed, `session_id` is nil → `build_request_events` returns `no_session`.

### Why — the structural differences (measured)

| | Claude Code (Anthropic) | Codex (OpenAI Responses) | OpenCode/Cursor (OpenAI Chat) |
|---|---|---|---|
| history | `messages[]` | **`input[]`** | `messages[]` |
| system prompt | `system` | **`instructions`** | `messages[0].role=="system"` |
| tools | `tools[].name` | `tools[].name` (flat) | **`tools[].function.name`** (nested) |
| tool names seen | Bash, Read, Edit, TodoWrite | exec_command, write_stdin, update_plan… | bash, edit, glob, grep, read… |
| session id | `metadata.user_id` | **headers**: `session-id`, `x-codex-turn-metadata` | **header**: `x-session-id` |
| tool call → result | `tool_use` / `tool_result` by `tool_use_id` | `function_call` / `function_call_output` by `call_id` | `tool_calls[].id` → `{role:"tool", tool_call_id}` |

`is_claude_code` matches on Anthropic-shaped `tools[].name` ∈ {Bash,Read,Edit,TodoWrite} or
"claude code" in `body.system` — neither exists for the others. Codex has no `body.system`
at all (it's `instructions`), and no `messages[]`.

## What this means

The gateway is a working **transport** for all five agents today, but a **guardrail** only
for Claude Code. Closing that is the codec/dialect/profile refactor: ~3 wire-format
adapters (Anthropic Messages, OpenAI Responses, OpenAI Chat) behind one interface, plus a
thin per-agent profile (identity, session extraction, chatter rules, `x-tool`). All of them
normalize into the **same hook events**, which is the backward-compatibility contract with
Straiker's coding-agent security model.

Notably, session identity is *easier* for the new agents than for Claude Code — Codex and
OpenCode both put a stable session id in **request headers** (no JSON-in-a-string parsing).

## Blocking dependency (backend)

`argus/api/helpers.py:215` — `is_coding_tools = x_tool in ("claude-code", "cursor")`.
`codex`, `opencode`, and `copilot` are **not** in the allowlist, so those events would be
rejected (HTTP 400) rather than routed to the coding pipeline. One-line backend fix.

Interim workaround if needed: send `x-tool: claude-code` for the new agents. Each still
lands in its **own collection**, because the collection is determined by the **detect key**,
not by `x-tool`.
