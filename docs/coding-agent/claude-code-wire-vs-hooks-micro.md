# Claude Code through the gateway: three commands, captured

**Answering the ask:** run `ls -l`, `echo`, and a file read on Claude Code and
show exactly what reaches the gateway, next to what the Straiker enforcement
hooks send. This is the small proof ahead of the full 500+ corpus.

Capture method: `claude -p "<prompt>"` with `ANTHROPIC_BASE_URL` pointed at a
byte-exact record-and-forward proxy, native Straiker hooks recording the same
session in parallel. Model: Claude Sonnet 4.5 (main) + Haiku 4.5 (utility).

## What one command actually sends

A single developer action is **not** one model call. `echo hello` produced four
HTTP requests to the gateway:

| # | Kind | Model | System prompt | Tools | Request size | Response |
|---|---|---|---|---|---|---|
| 1 | connectivity | — | — | — | 0 B | 200 |
| 2 | **utility (title-gen)** | Haiku 4.5 | 1.5 KB | 0 | 2.3 KB | text |
| 3 | **main turn** | Sonnet 4.5 | **29.9 KB** | **22** | **138 KB** | `tool_use: Bash` |
| 4 | main follow-up | Sonnet 4.5 | 29.9 KB | 22 | 139 KB | text (`end_turn`) |

`ls -l` and the file read are identical in shape (the read emits `tool_use: Read`
instead of `Bash`). Every scenario: one tiny utility call + one ~138 KB main
turn that carries a 30 KB system prompt and 22 tool schemas + one follow-up
carrying the tool result.

**This is the "verbose internal chatter" that breaks gateway guardrails.** A
naive input/output guardrail sees a 138 KB blob dominated by the system prompt,
tool schemas, and `<system-reminder>` scaffolding, with the actual user text
("echo hello") as a few bytes buried at the end of the last message. It either
scans the whole blob and false-positives on the scaffolding, or never finds the
user intent.

## The needle in the blob

The real user prompt lives in the **last user message, last text block**, after
three `<system-reminder>` blocks:

```
messages[0].content = [
  { type: text, text: "<system-reminder>… agent types …</system-reminder>" },
  { type: text, text: "<system-reminder>… skills …</system-reminder>" },
  { type: text, text: "<system-reminder>… memory/context …</system-reminder>" },
  { type: text, text: "echo hello" }          <-- the actual prompt
]
```

CVS's own captured samples show the *even harder* case: their gateway sees the
whole turn **flattened into a single string** — `<system-reminder>` blocks, the
user's `CLAUDE.md`, `<command-name>/model…</command-name>` slash-command output,
prior turns rendered as `user:` / `assistant:` lines, and the real prompt
("this is a test") trailing at the very end of 14–24 KB. Same problem, worse
shape.

## What the Straiker hooks send (the parity target)

For each of the three commands the native hooks emit a clean, typed sequence:

| Hook event | Carries | From the wire |
|---|---|---|
| `UserPromptSubmit` | the prompt only (`"echo hello"`) | last user text block, scaffolding stripped |
| `PreToolUse` | `tool_name` + `tool_input` (`Bash {command:"echo hello"}`) | the `tool_use` block in the response |
| `PostToolUse` | the tool's output | the `tool_result` block in the next request |
| `Stop` | — (telemetry) | `end_turn` response |

## The mapping the plugin implements

The gateway can reconstruct exactly that sequence from the wire:

- **last user text block, minus `<system-reminder>` / title-gen / suggestion /
  recap scaffolding → `UserPromptSubmit`.** Zero-tool utility calls (title-gen,
  Haiku suggestions) are dropped entirely — this is what kills the false
  positives.
- **`tool_use` block in the response → `PreToolUse`** (`tool_name` + `tool_input`
  verbatim).
- **`tool_result` block in the next request, matched by `tool_use_id` →
  `PostToolUse`** (carries the tool output — the indirect-injection surface).
- Session identity comes from `metadata.user_id` (a JSON string carrying a
  stable `session_id` that is constant across every request in the session).

These synthesized events are posted to `/api/v1/detect` with
`x-tool: claude-code` — the **same** backend pipeline the native hooks use — so
the Console shows them on the same Claude Code app card and scores them
identically.

## Two enforcement facts to state up front

1. **`PreToolUse` is genuine pre-execution enforcement**, but the gateway only
   sees the tool call in the model's *response*. To block it before the client
   runs it, the plugin holds the response until the `tool_use` is scored (see
   `latency-analysis.md` for the streaming trade-off).
2. **`PostToolUse` is one round-trip "late"** — the tool's output arrives on the
   *next* request. Detection is complete; at the gateway this is actually a
   *stronger* position than the endpoint hook, because a poisoned tool result
   can be blocked from ever reaching the model on that next request.
