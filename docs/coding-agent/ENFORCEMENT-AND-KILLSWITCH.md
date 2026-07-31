# Enforcement model + the kill-switch finding (v0.15.0)

## TL;DR

The gateway blocks a turn **whenever Straiker's decision is `action == "block"`** — for any
event, regardless of category/severity or which field carries it. This is a deliberate
change from mirroring the native hook contract (`hookSpecificOutput.permissionDecision ==
"deny"`), because that contract **cannot carry the kill switch on a prompt turn**. As a
result the gateway can **block plain conversational turns under the kill switch — something
the native Claude Code hooks structurally cannot do.**

## What we observed (direct signed probes against prod `/api/v1/detect`, kill switch ON)

Same event, two paths (enforce = no `Straiker-Debug`; debug = `Straiker-Debug: TRUE`):

| Event | Enforce path (`hookSpecificOutput`) | Debug path (`action`) |
|---|---|---|
| **UserPromptSubmit** | `{}` — no `permissionDecision` | `action=block, score=1.0` |
| PreToolUse (benign) | `deny` (once kill-switch state effective) | `action=block` |
| PostToolUse (benign) | `deny` | `action=block` |
| PreToolUse (real RCE) | `deny` | `action=block` |

The kill switch's block is present for **every** event on the **debug/scoring** path
(`action=block`), but the **enforce** path returns **`{}` for UserPromptSubmit** — so a
no-tool conversational turn has nothing to block on.

## Why (backend source — `argus/argus/api/helpers.py`, local main @ a582ee5, 2026-05-16)

- The coding-agent response is built in `helpers.py:225-296`.
- **Debug branch** (`helpers.py:250-270`) returns `action`/`score` and short-circuits
  **before** any event-type gate — that's why the Console/debug view shows `action=block`.
- **Enforce branch** (`helpers.py:271-296`) does, first thing (`helpers.py:277-278`):
  ```python
  if hook_event_name not in _TOOL_EVENTS:
      return JSONResponse(content={})
  ```
  `_TOOL_EVENTS` = {PreToolUse, beforeShellExecution, beforeMCPExecution, beforeReadFile,
  PostToolUse, postToolUse}. **`UserPromptSubmit` is not in it → returns `{}` before `action`
  is ever consulted.** `hookSpecificOutput.permissionDecision` (`helpers.py:290-296`) is only
  reached for tool events.
- `UserPromptSubmit` in the dispatcher (`hook_dispatcher.py:137-173`) is hardcoded to start
  the Redis trace and return `_ZERO_RESULT` — it can never carry a deny.
- The deny predicate (`helpers.py:240-247, 277-279`) requires **tool-event AND** `action=="block"`,
  and `action=="block"` requires mapped `score_category` **+** severity ∈ {high,critical} **+**
  Console category mode == BLOCK. A kill-switch block (`score=1.0`, `severity=null`,
  `category=null`) fails that — so even on a tool event it only denies once the kill-switch
  logic forces the mapping (prod carries kill-switch logic not present in this stale clone).

## Why the native hooks have the same blind spot

The installed handler (`artifacts/coding_agents/claude_code/mac/hook-handler.sh:264-270`)
blocks **only** on `hookSpecificOutput.permissionDecision == "deny"`:
```bash
DECISION=$(echo "$RESPONSE" | jq -r '.hookSpecificOutput.permissionDecision // empty')
if [ "$DECISION" = "deny" ]; then exit 2; fi
exit 0
```
It never looks at `action`. So for a kill-switched `UserPromptSubmit` the backend returns
`{}`, `DECISION` is empty, and the hook `exit 0` — **it does not block.** (An `exit 2` on
UserPromptSubmit *would* block the turn in Claude Code; the missing piece is purely that the
backend never emits the `deny` the handler keys on.) The user's "kill switch works on hooks"
was the **tool** turns (PreToolUse deny), not conversational ones.

## The gateway fix (v0.15.0) — `handler.lua` `enforce_decision()`

The gateway sees the full verdict, so it keys on the actual decision:

```lua
local verdict = score_sync(conf, ej)          -- scoring path: has `action`
if verdict.action == "block" then return true, verdict.reason end
```

Applied to UserPromptSubmit (pre-model), PreToolUse (response), PostToolUse (pre-model).
This blocks the kill switch on **every** turn type, including plain conversational turns —
the gateway advantage. Enforcement matrix:

| Event | Phase | Blocks on | Effect of a block |
|---|---|---|---|
| **UserPromptSubmit** | access (pre-LLM) | `action==block` | whole turn blocked; model never called |
| **PostToolUse** | access (pre-LLM) | `action==block` | poisoned tool result never reaches the model |
| **PreToolUse** | response | `action==block` | dangerous tool call never runs on the client |
| Stop | response | — (monitor only) | final answer; output-blocking is a separate toggle |

Two client-rendering fixes were required so the block actually shows in Claude Code:
- streaming block `message_start.content` must be `[]` (`cjson.empty_array`), not `{}`.
- `do_block()` type-guards the reason (Straiker returns `reason=null` → `cjson.null`, which is
  truthy in Lua) so the block always carries readable text.

Verified end-to-end: `claude -p` through Kong under the kill switch returns *"Request blocked
by Straiker guardrails."* instead of an answer.

## Recommended BACKEND change (so the NATIVE hooks also block conversational turns)

The gateway works around this today, but the native-hooks path still can't block a
conversational turn. Minimal backend edits (`argus/argus/api/helpers.py`):

1. **Emit deny for prompt events too.** Move the `action=="block"` → `permissionDecision="deny"`
   emission (`helpers.py:279-296`) **before** the `if hook_event_name not in _TOOL_EVENTS:
   return {}` guard (`helpers.py:277-278`), so any event with `action=="block"` returns the
   deny payload. This makes the native handler's `exit 2` fire on UserPromptSubmit.
2. **Make the kill switch force `action="block"` regardless of category/severity.** Extend the
   predicate at `helpers.py:240-247` so an app-level kill-switch flag (or `score >=
   block_threshold`) sets `action="block"` without requiring `score_category`/`severity` —
   otherwise a null-category/null-severity block is discarded even after fix #1.

## Operational note: kill-switch propagation

There appears to be a lag between toggling the kill switch in the Console and the enforce/
scoring path reflecting it (observed order-of-minutes). Not a gateway behavior — the gateway
acts on whatever `action` Straiker returns at request time.
