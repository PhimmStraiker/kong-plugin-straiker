# Claude Code through Kong at hook parity — results summary

**Question:** can we parse raw Claude Code traffic at Kong and reconstruct
Straiker detect payloads equivalent to what the enforcement hooks send —
achieving equal efficacy enforced at the gateway instead of the endpoint?

**Answer: yes, and it is built, live, and proven.** A new plugin
(`straiker-coding`, on branch `feat/claude-code-parity`) reconstructs Claude
Code hook events from the wire and posts them to `/api/v1/detect` with
`x-tool: claude-code` — the identical backend pipeline the native hooks use, so
parity is by construction: same detections, same Console coding-agent card.

## Why the current tooling fails (CVS's problem)

Claude Code sends a lot of "internal chatter." One `echo hello` is 4 requests:
a connectivity ping, a ~2 KB Haiku title-generation call, a **138 KB** main turn
(30 KB system prompt + 22 tool schemas + `<system-reminder>` scaffolding), and a
follow-up carrying the tool result. The real user prompt is a few bytes at the
end of the last message. CVS's captured samples are worse: the whole turn
**flattened into one 14–24 KB string** with the prompt trailing at the end.

A standard input/output guardrail scans that blob and false-positives on the
scaffolding — in a prior customer export, **~half of all "LLM Evasion"
detections were the guardrail firing on Claude Code's own machinery**, not user
input. In block mode that is a developer outage. That is exactly the pain that
blocks CVS from enabling Claude Code.

## What was built

Plugin `kong/plugins/straiker-coding/` (6 modules, ~500 LOC):

- `coding_agent.lua` — detects Claude Code traffic; extracts the clean prompt,
  `tool_use` (→ PreToolUse), and `tool_result` (→ PostToolUse); session id from
  `metadata.user_id`; chatter filter.
- `sse.lua` — reassembles Anthropic SSE (and shared assembly for Bedrock).
- `eventstream.lua` — decodes Bedrock `vnd.amazon.eventstream` binary frames.
- `detect.lua` — HMAC-signs and posts to `/api/v1/detect` with `x-tool`.
- `schema.lua` — `monitor`/`block` mode, chatter filter, session/user headers,
  and a guard that rejects the non-enforcing `/detect/webhook` path.
- `handler.lua` — `access` (request-side events) + `response` (PreToolUse);
  fail-open (a parser bug passes traffic through, never 500s the developer).

Plus a full lab (`lab-coding/`): a byte-exact capture proxy, a native-hook
recorder, a 39-scenario corpus generator, an offline parser-replay harness, a
parity comparator, and a local Kong 3.14 (docker-compose) with the plugin.

## Results — live and measured

**1. Monitor mode is live against the real Straiker backend.** Real Claude Code
sessions routed `ANTHROPIC_BASE_URL → Kong → Anthropic` produce the full
`UserPromptSubmit → PreToolUse → PostToolUse` sequence, each posted with a real
`turn_id`, visible on the **"Claude Code through Kong"** app card in the Console
(app `dapp_E2GkIaZn8AT`, your dedicated coding-agent key).

**2. Detection efficacy matches the hooks path.** Same malicious `tool_input`,
same score/category whether posted by the endpoint hook or the gateway:
base64→bash → `RCE` 0.55, curl|sh / reverse shell → `RCE` 0.59, cred exfil →
`Suspicious Outbound Access` 0.59.

**3. Block mode works end-to-end.** With a controlled deny policy, a live Claude
Code tool call (`printenv`) through Kong was blocked — the plugin replaced the
model's `tool_use` response with an Anthropic block message and the tool never
executed. Claude Code showed: *"Blocked by Straiker (lab policy: 'printenv')."*

**4. Parity across the corpus** (`parity/parity_check.py`, Kong-synthesized vs
native hooks, same sessions):

```
event              recall    precision   (kong / native / matched)
UserPromptSubmit   100.0%    95.1%       (41 / 39 / 39)
PreToolUse         100.0%    100.0%      (105 / 105 / 105)
PostToolUse        100.0%    91.4%       (105 / 96 / 96)
```

Across 39 sessions / 167 model calls: the gateway captures **every** tool call
the model emits (`PreToolUse` 100%/100%, security-relevant `tool_input` identical
to the hook) and **every** prompt (`UserPromptSubmit` 100% recall). The only
residuals are the gateway being *more* complete: it emits `PostToolUse` for
force-blocked/errored tool results the native hook skips, and counts a subagent's
own prompt turn.

**5. Bedrock (CVS's transport) is handled.** Request format is identical
Anthropic Messages (parser unchanged); the `vnd.amazon.eventstream` response
decoder was verified on a real Bedrock capture (recovered the `Bash` tool_use +
`stop_reason`).

**6. Latency:** Kong adds negligible *total* latency (~50–200 ms; monitor
scoring is async). Buffering to enable response-side blocking pushes
*time-to-first-token* from ~0.6 s to the full response time (~4 s here); a
streaming-hold variant (fast-follow) recovers it. See `latency-analysis.md`.

## Honest caveats / what's a policy vs a plugin matter

- **Blocking these RCE detections requires backend severity tuning.** They score
  `severity: low` today, and the backend block gate needs `high`/`critical`. So
  they *detect* but don't *block* by default — **identical for the native hooks**
  (same pipeline). Turning detections into blocks is a Console policy exercise.
- **Claude models self-refuse obvious attacks**, so they rarely emit the
  malicious `tool_use`. Attack detection is proven by posting the tool call
  directly (hooks and gateway both do this); the corpus proves benign/realistic
  parity across the full tool surface.
- **Routing Bedrock through Kong needs SigV4 handling** (Kong `aws-request-signing`
  or client-unsigned-to-Kong). The plugin parsing is transport-agnostic; this is
  a deployment step.

## For the CVS deadline

- The plugin meets the ask: guardrails that handle Claude Code's gateway-mode
  format and reach hook-parity efficacy, in `monitor` (safe first-enable) with
  `block` ready. Recommend enabling **monitor-first** so a scaffolding false
  positive can never cause a first-day outage — the exact failure their legacy
  tooling has.
- Next steps for a CVS pilot: (a) stand the plugin on their Kong in monitor mode
  against a CVS Defend key; (b) wire Bedrock SigV4; (c) tune which detections
  block via Console severity policy; (d) fast-follow the streaming-hold variant.

## Repo

- Branch `feat/claude-code-parity` off `straiker-ai/kong@main` (synced).
- Plugin: `kong/plugins/straiker-coding/` + restored `straiker-shared/` translators.
- Docs: `docs/coding-agent/{SUMMARY,mapping-analysis,latency-analysis,claude-code-wire-vs-hooks-micro}.md`.
- Lab: `lab-coding/` (captures + rendered configs are gitignored — they hold keys).
