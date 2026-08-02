# Two enforcement modes — pick one per route

Straiker ships **two plugins** for coding-agent traffic. They share the same parser, the
same hook events, and the same Straiker pipeline. They differ in one thing: whether the
gateway **holds the model's response** before passing it to the developer.

That single difference is a genuine security-vs-experience tradeoff, and it is the
customer's call — not a default we impose.

| | `straiker-coding` | `straiker-coding-stream` |
|---|---|---|
| **Time to first token** | ~17s (the whole answer arrives at once) | **~1.4s** (normal streaming) |
| Total time | the same | the same |
| Blocks the **prompt** (kill switch, prompt injection) | ✅ | ✅ |
| Blocks a **poisoned tool result** reaching the model | ✅ | ✅ |
| Blocks a **dangerous tool call before it executes** | ✅ | ❌ reported, not prevented |
| Console visibility (all four hook events) | ✅ | ✅ |

Measured on a 500-word answer through a live gateway. Note the **total** time is
effectively identical — buffering does not make the model slower, it withholds the output
until the whole answer exists. What the developer experiences as "the gateway is slow" is
~16 seconds of dead air, not added compute.

## Why the difference exists (and can't be a checkbox)

Kong decides response buffering from whether a plugin implements the `response` phase,
evaluated before any plugin code runs
(`kong/runloop/plugins_iterator.lua:521` — `if phase == "response" then ctx.buffered_proxying = true`).
Buffering is what makes it possible to remove a tool call from a response before the client
sees it. No runtime flag can turn that off, which is why the two modes are two plugins
rather than one setting. Attach whichever the route needs.

## Choosing

**Choose `straiker-coding` (buffered) when** the agent runs with broad permissions against
sensitive systems and preventing a single dangerous tool call matters more than
interactivity — production agents, CI/CD, anything with write access to prod. Blocking is
also visually decisive here: the response is replaced wholesale, so a denied turn simply
stops.

**Choose `straiker-coding-stream` when** developers are working interactively and the 16s
of dead air would drive them to bypass the gateway entirely. You keep the kill switch,
prompt-level blocking, and poisoned-tool-result blocking; you lose pre-execution tool
blocking. A guardrail developers disable protects nothing — for interactive use this is
usually the right trade.

Both can run simultaneously on different routes, so a single gateway can serve
interactive developers on one and production agents on the other.

## What blocking looks like in each mode

Prompt-level blocks (the kill switch, prompt injection) behave **identically** in both
modes: they fire in the `access` phase, before the model is ever called, and the client
receives a well-formed message carrying the block reason. Nothing is generated, so nothing
has to be retracted.

The modes only diverge **mid-turn**: the buffered plugin can still deny a tool call after
the model has produced it; the streaming plugin has already sent those bytes and can only
report it.

## Configuring

```
# interactive developers — streaming
plugin: straiker-coding-stream
config: { api_key: <Claude Code key>, detect_url: .../api/v1/detect,
          x_tool: claude-code, mode: block, fail_open: true }

# production agents — full enforcement
plugin: straiker-coding
config: { ...identical... }
```

Do **not** attach both to the same service or route: the buffered one wins (it forces
buffering for everything on that route), so the streaming plugin's benefit disappears
while both still score. Kong applies service-scoped plugins to every route on that
service — a common way to do this by accident.

`fail_open: true` is recommended in both modes: if Straiker is unreachable, traffic passes
rather than developers being blocked by a guardrail outage.
