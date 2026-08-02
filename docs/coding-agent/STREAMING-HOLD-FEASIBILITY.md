# Streaming hold: not achievable in Kong (and why LiteLLM can do it)

**Goal.** One plugin that streams text deltas straight through (~1s to first token) while
holding only the `tool_use` frames until Straiker scores them — then releasing or denying.
That would give pre-execution tool blocking *and* native streaming, collapsing the current
two-plugin choice.

**Finding: this is not implementable in Kong/OpenResty as a deterministic security
control.** Not a matter of effort. Three constraints compose into a wall.

## 1. Implementing `response` forces buffering

`kong/runloop/plugins_iterator.lua:521`

```lua
if phase == "response" and not ctx.buffered_proxying then
  ctx.buffered_proxying = true
```

Buffering is decided from the *existence* of a `response` field on the handler table, in
the plugin iterator, before any plugin code runs. So the streaming path must use
`body_filter`, not `response`. (Verified: a runtime `enforcement=streaming` flag inside
`:response()` still measured 19.6s TTFT on a control plane with no other plugins.)

## 2. `body_filter` cannot make the scoring call

OpenResty disables yielding APIs — cosockets, `ngx.sleep`, `ngx.thread` — in
`body_filter_by_lua*`. `resty.http` is a cosocket client, so the Straiker call is
impossible there. Corroborated in this image: **no bundled Kong plugin performs HTTP from
`body_filter`.**

## 3. You cannot await the verdict either

The obvious workaround — spawn `ngx.timer.at` (timers *may* use cosockets) and wait on an
`ngx.semaphore` — fails because `semaphore:wait()` yields, which is exactly what
`body_filter` forbids.

What remains technically possible is a **best-effort hold**: suppress the `tool_use`
frames (`ngx.arg[1] = nil`), score in a timer, and release on a *later* `body_filter`
invocation if the verdict happened to arrive. That is a race — at end-of-stream there may
be no further invocation and no way to wait, so the plugin must fail open. **A control
that enforces only when it wins a race is not a security control**, and shipping it as one
would be worse than the honest two-plugin split.

## Consequence: the two modes are inherent, not a design shortcut

| | `straiker-coding` | `straiker-coding-stream` |
|---|---|---|
| Blocks a tool call pre-execution | ✅ deterministic | ❌ post-hoc report |
| Time to first token | ~17s | ~1s |

Both keep prompt-level (kill switch) and poisoned-tool-result blocking, because those run
in `access` before the model is called, where cosockets are allowed.

## This is where LiteLLM differs — worth knowing for the comparison

LiteLLM is Python/asyncio. A custom guardrail runs inside an `async` handler and can
`await` mid-stream: hold a tool-call chunk, `await` the Straiker call, then yield or drop
the chunk. There is no equivalent of OpenResty's no-yield filter phase.

So **LiteLLM can implement the streaming hold and Kong cannot.** That is a genuine
architectural difference between the two gateways, not a maturity gap, and it should
inform which one is recommended where:

- **Kong** — enterprise API gateway already deployed, mature policy/auth/rate-limiting,
  Lua plugin ecosystem. Coding-agent enforcement must choose buffered *or* streaming.
- **LiteLLM** — LLM-native proxy, Python guardrails, can do streaming + pre-execution tool
  blocking simultaneously. Less of an enterprise gateway.

## If the streaming hold is required on Kong

Options, in increasing cost:

1. **Accept the split** (current). Interactive developers on streaming; production agents
   buffered. Documented in `ENFORCEMENT-MODES.md`.
2. **Score speculatively.** Tool calls repeat across a session; cache verdicts by
   `tool_name` + argument hash in `access` (cosockets allowed) and let `body_filter` check
   the cache with no I/O. Blocks *repeat* dangerous calls at streaming speed; first
   occurrence still passes. Partial control, honestly labelled.
3. **Move the hold out of Kong** — a sidecar (Go/Rust/Python) that Kong forwards to, doing
   the hold where yielding is permitted. Real, and real operational weight.
