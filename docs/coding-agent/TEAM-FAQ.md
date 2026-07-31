# Claude Code + Kong + Straiker — team FAQ

Answers to the questions raised while building/validating the `straiker-coding`
Kong plugin. Deep detail on parsing/mapping is in **`PLUGIN-GUIDE.md`**; latency
detail in **`latency-analysis.md`**; the real exported data in
`lab-coding/konnect/out/engineering/`.

---

### Q: How are the Claude Code requests generated? Are you spinning up sub-agents?

**No sub-agents.** Every request is the **real Claude Code CLI** (`claude`,
v2.1.220 — the same binary you run) invoked headlessly: `claude -p "<prompt>"`,
each in its own isolated `HOME` and workspace, with `ANTHROPIC_BASE_URL` (or the
Bedrock equivalent) pointed at the Kong data plane. We ran ~50 different prompts as
50 separate real CLI processes (concurrency-limited), and each one produced the
genuine Claude Code multi-call flow (title-gen + main turn + a follow-up per
tool). Nothing is simulated or constructed — the traffic is exactly what Claude
Code emits, captured by Kong. (An earlier attempt used *constructed* request
bodies; that was scrapped — the entire current dataset is real CLI traffic.)

---

### Q: What are the latency differences — direct vs through Kong with guardrails?

Measured on the Konnect data plane with a deterministic request (median of 5):

| Path | Median total | Added vs direct | Token streaming? |
|---|---|---|---|
| **Direct** Claude Code → Anthropic | ~0.79 s | — | yes (first token ~0.5 s) |
| **Kong → transparent detection** (monitor, async scoring) | ~0.65 s | **≈ 0** (proxy hop is tens of ms; guardrail call is fire-and-forget) | **no — buffered** |
| **Kong → sync scoring** (used to log the verdict) | ~0.88 s | **~+95 ms** (two inline Straiker round-trips) | **no — buffered** |

Two separate effects, and they matter differently:

1. **Added latency is small.** In transparent (async) mode the guardrail adds
   essentially nothing to total time — the detect call runs in a background timer
   after the response is already on its way back. Sync scoring (only needed to put
   the verdict *into the Kong log*) adds ~95 ms because it waits for Straiker
   inline. This scales with events per call (UserPromptSubmit + PreToolUse), each
   ~40–100 ms.
2. **Token streaming is lost in every mode.** The plugin buffers the model
   response so it can see the `tool_use` block (needed for `PreToolUse` and for
   blocking). So the developer waits for the **whole** response (~5 s on a long
   answer) instead of seeing the first token in ~0.5 s. *Total* time is about the
   same; *perceived* responsiveness is worse. This is the real UX cost, and it is
   independent of the scoring mode.
   - Fix (documented, not yet built): a streaming-hold variant that streams text
     through untouched and only holds `tool_use` frames — restores first-token
     latency while keeping enforcement. See `latency-analysis.md`.

---

### Q: Is there a "transparent" mode where it's just detection? Does it inherit the config?

**Yes.** Transparent detection = **`mode: monitor` with `log_serialize: false`**
(the plugin default). In that mode every synthesized event is POSTed to Straiker
**fire-and-forget** (an `ngx.timer`), so Straiker sees everything — the full
`UserPromptSubmit`/`PreToolUse`/`PostToolUse` stream, visible on the Console
coding-agents card — while the developer experiences ~zero added latency and the
request is never blocked.

It is the **same plugin, same configuration** — it inherits `api_key`,
`detect_url`, `x_tool`, `session_header`, `chatter_filter`, signing, etc. The only
knobs that change behavior:

| Goal | `mode` | `log_serialize` | Effect |
|---|---|---|---|
| **Transparent detection** (lowest latency) | `monitor` | `false` | async scoring, ~0 added latency, never blocks |
| **Detection + full Kong log/export** | `monitor` | `true` | sync scoring so the verdict lands in Kong's log (~+95 ms); what we use for the engineering export |
| **Enforcement** | `block` | either | denies a tool call whose verdict is `deny` (buffered) |

So "just turn on detection" is: install the plugin, `mode: monitor`, done — no
extra config. Turn on `log_serialize` only when you want Kong's log to carry the
raw bodies + verdict for export.

---

### Q: How do I point MY Claude Code here at the Kong gateway, and toggle it?

The Kong DP is on `http://localhost:8000`. Source the toggle helper once:

```bash
source lab-coding/konnect/claude-kong-toggle.sh
```

Then, in any shell:

```bash
kong-on         # Claude Code → Kong → Anthropic   (guardrails ON)
kong-off        # back to direct                    (guardrails OFF)
kong-status     # show current routing
claude          # your normal, logged-in Claude Code — now routed through Kong
```

- It only sets `ANTHROPIC_BASE_URL`; your existing login (OAuth/subscription) is
  untouched — Kong forwards your auth to Anthropic after guardrailing.
- **Heads-up:** while `kong-on`, responses arrive complete (buffered), not
  token-streamed — expected, see the latency answer.
- Watch it work: `docker logs -f straiker-konnect-dp | grep straiker-coding`, and
  the turns appear in Straiker under the **Claude Code through Kong** app.

**Bedrock toggle:** set a Bedrock API key first, then `kong-bedrock-on`:
```bash
export AWS_BEARER_TOKEN_BEDROCK="<ABSK… bedrock api key>"   # see PLUGIN-GUIDE §7b to mint one
kong-bedrock-on         # Claude Code (Bedrock) → Kong → Bedrock (guardrails ON)
```

---

### Q: What exactly does the plugin parse, and how does it map to Claude Code?

Full detail + the event-synthesis summary table + the multi-call timeline (when
`UserPromptSubmit` / `PreToolUse` / `PostToolUse` fire across a session's model
calls) is in **`PLUGIN-GUIDE.md`** §2–§5. In one line: it detects Claude Code
traffic, pulls the **user prompt** from the last non-`<system-reminder>` text
block, the **tool calls** from the response `tool_use` blocks, and the **tool
results** from the next request's `tool_result` blocks, dedups the resent
transcript, and POSTs each as a hook event to `/api/v1/detect` with
`x-tool: claude-code` (HMAC-signed) — the same endpoint the native Claude Code
hooks use.

---

### Q: Is this going into the real straiker-ai plugin?

That's the intent — it's built as an enterprise-grade update on
`feat/claude-code-parity` (pushed to the PhimmStraiker fork only, **not** yet to
straiker-ai). The one Kong-level addition beyond the plugin is `file-log` (for the
export); Bedrock with SigV4 (instead of a bearer key) would also want
`aws-request-signing` on the Bedrock route. Neither changes the plugin itself.
