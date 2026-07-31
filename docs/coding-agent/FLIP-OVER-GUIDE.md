# Flip Claude Code over to Kong (basic guide)

Two things to set up, in this order:

1. **A new, dedicated guardrail profile in Kong** for the Claude Code path — its own
   `straiker-coding` plugin instance, configured with a **Claude Code key** (not the
   standard API key).
2. **Point Claude Code at the Kong gateway** (one env var — reversible in one command).

---

## What changes on your machine when you flip (and what doesn't)

**The only client-side change is one environment variable.**

```bash
export ANTHROPIC_BASE_URL="http://localhost:8000"   # Anthropic path — this is the whole flip
# (Bedrock instead: CLAUDE_CODE_USE_BEDROCK=1 + ANTHROPIC_BEDROCK_BASE_URL=<kong>)
```

**What does NOT change** (nothing is written or migrated):
- Your **login** — Claude Code sends your normal OAuth token; Kong forwards it to Anthropic,
  which authenticates it. No API key needed. (Verified: a real prompt returned through Kong
  on the live OAuth login.)
- `~/.claude/` — settings, MCP servers, hooks, permissions, memory: **untouched**.
- **Model, tools, agent behavior, your projects** — identical.
- **Any already-running `claude` session** — the env var only affects **new** `claude`
  processes started in a shell where it's set. Existing sessions keep going direct.

**What changes in behavior** (the effects of routing through Kong):
- **Path:** `Claude Code → Kong (localhost:8000) → Anthropic` — one extra local hop.
- **Guardrails apply:** every turn/tool call is scored by Straiker. In **block** mode a deny
  verdict blocks that request/tool. This is the point.
- **Streaming → buffered:** the plugin buffers the response, so it arrives **complete rather
  than token-by-token**. Functionally fine; the visible difference is a pause, then the whole
  answer (no live streaming). This is the most noticeable UX change.
- **Latency:** a modest per-call add for the sync detect (~tens–~100 ms); model time
  dominates (a tiny prompt round-tripped in ~4–5 s).
- **Depends on the Kong DP being up.** `fail_open` covers *Straiker* being unreachable — it
  does **not** cover *Kong* being down. If the `straiker-konnect-dp` container is stopped
  while the env var is set, Claude Code can't reach Anthropic. Fix = unset the var (rollback)
  or start the container.
- **Console visibility:** your real coding turns appear on the Straiker coding-agent card.

**Rollback is total and instant** because nothing else changed:
```bash
unset ANTHROPIC_BASE_URL      # (or: kong-off, or just close that terminal)
```

---

## 1. Create a NEW guardrail profile in Kong — and use a Claude Code key

**This path cannot run off the standard "API" key.** In Straiker there are two different
key types, and they are not interchangeable:

| Key type | What it is | Where it routes |
|---|---|---|
| **Standard API key** | the **collection key** for normal app / chatbot traffic | the app's regular prompt/response collection |
| **Claude Code key** | the coding-agent key (same type the native Claude Code hooks use) | the **coding-agent** pipeline (`x-tool: claude-code` → HookDispatcher) |

If you point the plugin at the **standard API key**, the coding events land in that key's
**collection** and collide with your regular app traffic — wrong pipeline, wrong policy,
mixed data. The plugin sends `x-tool: claude-code`, so it needs a **Claude Code key** to
route to the coding-agent path and get its own coding-agent card in the Console.

So: **create a new guardrail profile in Kong** — a *separate* `straiker-coding` plugin
instance dedicated to the Claude Code route — and set its `api_key` to a **Claude Code
key**, not the standard API/collection key.

**Do it once:**

1. In Straiker, provision a **Claude Code key** for the coding agent (this is a distinct
   key type from the standard API key). *(In this lab that key is `0d51fa60-…`,
   deliberately kept out of the standard demo SE / collection key so it shows separately.)*
2. In Kong, add a **new `straiker-coding` plugin** on the Claude Code route/service and
   put that Claude Code key in `config.api_key`. Don't reuse an existing Straiker plugin
   instance that carries the standard API key — stand up its own profile.

Rule of thumb: **one guardrail profile per traffic source, keyed by the matching key
type.** Gateway Claude Code → its own Kong profile + a Claude Code key. Regular app
traffic → the standard API (collection) key. Never cross them.

---

## 1b. Why a separate profile — and how it sits next to the standard Straiker plugin

**Why a new profile is *required*, not just tidy.** A Kong plugin instance's config holds
**exactly one `api_key`** (it's a single required string in the schema — there is no
multi-key field). So a Straiker key and a plugin instance are 1:1. A **second** Straiker
key — the Claude Code key here — **must** be a **second plugin instance**. That is what a
"new guardrail profile" means in Kong: another plugin instance carrying the second key.

**They're two different plugins, so they coexist cleanly:**

| Guardrail profile | Plugin | Priority | Key | Guards |
|---|---|---|---|---|
| Standard | `straiker` | **760** | standard **API (collection) key** | regular app / chatbot traffic |
| Claude Code | `straiker-coding` | **755** | **Claude Code key** | Claude Code (`x-tool: claude-code`) |

Different plugin **names**, so Kong lets both exist. Kong also allows **only one instance
of a given plugin name per scope** (route/service) — which is exactly why one instance
can't hold two keys, and why the second key rides a second instance.

**Recommended topology — separate routes (clean isolation):**

```
                    ┌─ Kong route: /app  ──── straiker (760, standard API key) ──▶ chatbot/app upstream
Kong proxy ────────►┤
                    └─ Kong route: /cc   ──── straiker-coding (755, Claude Code key) ─▶ Anthropic / Bedrock
```

- Put the **standard `straiker`** plugin on the route(s) for regular app traffic, with the
  **standard API key**.
- Put the **new `straiker-coding`** plugin on a **dedicated Claude Code route/service**
  (the one Claude Code points at), with the **Claude Code key**.
- Because each plugin lives on its **own route**, only the matching one runs. No collision,
  no double-scoring, each key isolated. **This is the recommended setup.**
- Give Claude Code its own gateway address so it lands on the `/cc` route — set its
  `KONG_URL` (below) to that route's host/path. Regular apps keep pointing at their route.

**If Claude Code and regular traffic must share ONE route** (same upstream, can't split):
both plugins attach and **both run**, ordered by priority — `straiker` (760) first, then
`straiker-coding` (755). That means each request is processed by **both**: the standard
plugin tries to parse Claude Code's verbose format (the very thing that breaks legacy
guardrails — the original pain), and the coding plugin parses ordinary chatbot turns as if
they were Claude Code. **Not recommended.** If you can't split routes, disable the standard
`straiker` plugin on that route (leave only `straiker-coding`), or gate each plugin by
path/header so only one applies. **Splitting routes is the right answer.**

---

## 2. Configure the new plugin instance on your Kong route

Attach the new `straiker-coding` profile to the Kong **service/route** that fronts the LLM
(Anthropic and/or Bedrock). Minimum config:

```
name: straiker-coding
config:
  api_key:  <a Claude Code key>                            # NOT the standard API/collection key
  detect_url: https://<your-straiker>/api/v1/detect        # NOT /webhook
  x_tool:   claude-code
  mode:      block         # plugin ENFORCES Straiker's verdict (monitor = observe only)
  fail_open: true          # if Straiker is unreachable/times out -> ALLOW (never break coding)
  debug:     false         # REQUIRED for enforcement: Straiker-Debug + block are mutually exclusive
```

**Enforcement posture (recommended for real use): `mode=block`, `fail_open=true`,
`debug=false`.** The plugin then faithfully enforces whatever Straiker returns, allows on a
guardrail outage, and — because `debug` is off — actually receives deny decisions (with
`debug:true` the backend returns a score breakdown *instead of* the deny, so nothing blocks).
**You drive the real block / detect / disable policy per category at the Straiker Console**;
the plugin just enforces it. To flip the deployed plugin to this posture idempotently:

```bash
set -a && source .env.konnect && set +a
python3 lab-coding/konnect/set_plugin_config.py     # sets mode=block, fail_open=true, debug=false
```

Create it on Konnect with a **POST** (new profile), or **PUT** to update an existing one
(PATCH returns 405):

```bash
# NEW guardrail profile on the Claude Code route:
curl -sS -X POST \
  "https://<region>.api.konghq.com/v2/control-planes/$CP_ID/core-entities/routes/$CC_ROUTE_ID/plugins" \
  -H "Authorization: Bearer $KONNECT_PAT" -H "Content-Type: application/json" \
  -d '{"name":"straiker-coding","config":{"api_key":"<claude-code-key>",
       "detect_url":"https://<your-straiker>/api/v1/detect","x_tool":"claude-code","mode":"monitor"}}'
```

`monitor` scores + lights up the Console but never denies live traffic (no first-day FP
outage). Flip `mode` to `block` when you've watched it and trust it. See PLUGIN-GUIDE.md
for the full field list (session header, user_name, sign_payloads, timeout, fail_open).

---

## 3. Point Claude Code at the gateway (the actual "flip")

Source the toggle helpers, then one command flips you on/off. Your normal `claude` OAuth
login is untouched — this only redirects the base URL, which Kong forwards upstream after
guardrailing.

```bash
source lab-coding/konnect/claude-kong-toggle.sh   # defines kong-on / kong-off / kong-status
export KONG_URL="https://<your-kong-proxy-host>"  # your gateway (defaults to http://localhost:8000)

kong-on            # Claude Code -> Kong -> Anthropic  (guardrails ON)
kong-status        # shows where you're pointed
kong-off           # back to direct (guardrails OFF)
```

Under the hood `kong-on` just sets one env var:

```bash
export ANTHROPIC_BASE_URL="$KONG_URL"     # Anthropic path
```

**Bedrock instead:** set a Bedrock API key first, then `kong-bedrock-on`:

```bash
export AWS_BEARER_TOKEN_BEDROCK="<ABSK... bedrock api key>"
kong-bedrock-on    # sets CLAUDE_CODE_USE_BEDROCK=1 + ANTHROPIC_BEDROCK_BASE_URL=$KONG_URL
```

That's the whole flip. `kong-off` (or unsetting `ANTHROPIC_BASE_URL` /
`ANTHROPIC_BEDROCK_BASE_URL`) puts you back to direct at any time.

**Terminal vs. desktop GUI app.** The env-var flip applies to `claude` launched from **that
shell** (any terminal — system Terminal, iTerm, the VS Code integrated terminal). It is
per-process and fully isolated: other shells, other sessions, and the machine as a whole are
untouched. A macOS **GUI** app does **not** inherit shell env vars, so to route the desktop
app you'd set it at the login-session level and relaunch the app:

```bash
launchctl setenv ANTHROPIC_BASE_URL http://localhost:8000   # affects GUI apps; persists until unset/logout
# rollback:
launchctl unsetenv ANTHROPIC_BASE_URL                       # then relaunch the app
```

This is more global than the terminal path (it affects every GUI app that reads the var), so
prefer the per-terminal flip unless you specifically need the desktop app routed.

---

## 4. Verify it's flowing to the *right* profile

Send one prompt through, then in the Console open the **coding-agent** view for the
**Claude Code key** you configured. You should see coding-agent events (UserPromptSubmit /
PreToolUse / PostToolUse) show up there **and nowhere else** — in particular *not* mixed
into your standard-API-key collection. That's the proof the new guardrail profile is
isolated on its own Claude Code key and nothing collided.

> Note: `Straiker-Debug: TRUE` and enforcement are mutually exclusive backend-side. Leave
> debug off in `block` mode.
