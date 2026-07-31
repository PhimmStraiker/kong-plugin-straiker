# Flip Claude Code over to Kong (basic guide)

Two things to set up, in this order:

1. **A dedicated Straiker "coding agent" guardrail profile** (its own app / collection
   key) so gateway traffic doesn't collide with your other collections.
2. **Point Claude Code at the Kong gateway** (one env var — reversible in one command).

---

## 1. Give it its own coding-agent guardrail profile (own collection key)

The plugin's `config.api_key` is a Straiker **app-scoped detect key**. That key *is* the
collection: every event the plugin posts (`x-tool: claude-code`) lands in the app that
key belongs to. If you reuse an existing app's key, gateway events **collide** with that
app's traffic in the Console — same collection, mixed sources, mixed policy.

So create a **separate Straiker app** for the Kong-gateway coding traffic and use *its*
detect key. Then the gateway path has its own card, its own policy (monitor vs block),
and its own history — cleanly isolated from:

- the endpoint **hook** coding agent (if you also run Claude Code hooks), and
- any chatbot / other app collections on the same tenant.

**Do it once:**

1. Straiker Console → create an app, e.g. **"Claude Code — Kong Gateway"** (coding-agent
   type). Copy its detect key. *(For this lab we used the dedicated coding-agent key
   `0d51fa60-…`, deliberately kept out of the demo SE key so it shows separately.)*
2. Put that key in the plugin config (below). Nothing else shares it.

Rule of thumb: **one guardrail profile per traffic source.** Gateway = its own app key.
Hooks = their own. Chatbots = theirs. Keys are the collection boundary — don't cross them.

---

## 2. Configure the plugin on your Kong service

The plugin attaches to the Kong **service/route** that fronts the LLM (Anthropic and/or
Bedrock). Minimum config:

```
name: straiker-coding
config:
  api_key:  <the dedicated coding-agent app detect key>   # <-- the collection key from step 1
  detect_url: https://<your-straiker>/api/v1/detect        # NOT /webhook
  x_tool:   claude-code
  mode:     monitor        # start here; flip to "block" when you're ready
```

Update it on Konnect with a **PUT** to the plugin (PATCH returns 405):

```bash
curl -sS -X PUT \
  "https://<region>.api.konghq.com/v2/control-planes/$CP_ID/core-entities/plugins/$PLUGIN_ID" \
  -H "Authorization: Bearer $KONNECT_PAT" -H "Content-Type: application/json" \
  -d '{"name":"straiker-coding","config":{"api_key":"<coding-agent-app-key>",
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

---

## 4. Verify it's flowing to the *right* collection

Send one prompt through, then in the Console open the **"Claude Code — Kong Gateway"** app
(the one whose key you configured). You should see coding-agent events
(UserPromptSubmit / PreToolUse / PostToolUse) show up there **and nowhere else** — proof
the collection key is isolated and nothing collided.

> Note: `Straiker-Debug: TRUE` and enforcement are mutually exclusive backend-side. Leave
> debug off in `block` mode.
