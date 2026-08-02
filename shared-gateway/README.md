# Straiker shared Claude Code gateway — **LIVE at `https://konggw.dev.straiker.ai`**

One hosted, Straiker-guardrailed endpoint the whole team points `ANTHROPIC_BASE_URL` at —
no per-person local proxy. Internet-reachable but **key-auth gated to Straiker folks**, on
its **own** Konnect control plane (`straiker-shared-kong-gateway`), separate from SE demo.

**Status: verified end-to-end.** Real Claude Code through the gateway returns normally
(~5 s for a one-line prompt); `no key` → Kong `"No API key found in request"`; a valid key
forwards upstream to Anthropic.

## Why we self-host the data plane (and don't use Kong's SaaS gateways)

Kong Konnect *does* offer hosted data planes, and **Dedicated Cloud Gateways even support
custom Lua plugins** ("Custom Plugin Streaming" — you upload `handler.lua`/`schema.lua` and
Konnect distributes them). **Serverless Gateways explicitly do not.** We still self-host,
because `straiker-coding` cannot run on a DCG as written:

| Need | On Dedicated Cloud Gateways |
|---|---|
| `lua_shared_dict straiker_coding 32m` (cross-request dedup) | ❌ `ngx.shared` isn't in the sandbox allowlist, and `KONG_NGINX_HTTP_*` injection is "Incompatible with: konnect" |
| `ngx.timer.at` (async detect posting) | ❌ custom plugins "cannot… create timers" |
| 6 Lua modules | ❌ exactly one `handler.lua` + one `schema.lua`, ≤100 KB, no custom modules |
| `resty.http` | ⚠️ requires `KONG_UNTRUSTED_LUA=lax` |
| `resty.openssl.hmac`, `enable_buffering()` | ✅ allowed |

The shared dict is load-bearing: without it the agentic loop's resent transcript is
re-scored every turn. So Kong hosts the **control plane**; we host the **data plane** on
App Runner and supply the URL.

```
teammate (Claude Code, own login)          konggw.dev.straiker.ai (App Runner)
  ANTHROPIC_BASE_URL = https://konggw…  ─▶  key-auth  → only Straiker key-holders
  ANTHROPIC_CUSTOM_HEADERS: apikey:…         straiker-coding → guardrails (block+fail_open)
                                             identity = the key's consumer (auto)
                                        ─┬─▶ Straiker /api/v1/detect
                                         └─▶ api.anthropic.com (forwards their login) / Bedrock
```

## What's already done (this repo)
- **Control plane** `straiker-shared-kong-gateway` created; DP cert generated + pinned
  (`01_create_control_plane.py` → `cp.env`, `secrets/tls.{crt,key}` — git-ignored).
- **CP configured** (`02_configure_cp.py`): Anthropic (`/v1/messages`) + Bedrock (`/model`)
  services/routes, `straiker-coding` (mode=block, fail_open=true, debug/log off), and
  **key-auth** (`apikey` header, credentials hidden from upstream) on both.
- Plugin resolves identity from the **authenticated key-auth consumer** first (v0.16.0), so
  each teammate shows as themselves in the Console with no extra header.

## Deploy the data plane (needs refreshed AWS creds)
```bash
# after: aws sso login  (or refresh STS)
cd shared-gateway/apprunner && ./deploy.sh
```
`deploy.sh` builds the DP image (plugins baked in), pushes to ECR, stores the cluster
cert/key in Secrets Manager, creates/updates the App Runner service, and associates the
custom domain. First run needs two IAM roles (it tells you which) and, after it prints the
App Runner CNAME targets, add them to the `dev.straiker.ai` zone so the domain validates.

## Onboard / offboard teammates
```bash
set -a && source ../.env.konnect && set +a
python3 03_provision_user.py add    alice@straiker.ai     # prints her key + setup line
python3 03_provision_user.py list
python3 03_provision_user.py revoke alice@straiker.ai
```

## What a teammate does (once)
```bash
export KONGGW_KEY='<key from you>'
source konggw-toggle.sh
konggw-on            # or konggw-bedrock-on (needs their own AWS_BEARER_TOKEN_BEDROCK)
# … use Claude Code normally …
konggw-off           # back to direct
```

## Notes
- **Identity/collection:** currently uses the coding-agent key `0d51fa60…`. Consider a
  **dedicated Claude Code key** for the shared instance so its collection is separate from
  the SE-demo coding tests (swap `api_key` in `02_configure_cp.py` + re-run).
- **Bedrock auth:** teammates pass their own Bedrock token (forwarded). Swap to a shared
  Bedrock key on the route if not everyone has AWS.
- **Buffered** (no token streaming), same as the local plugin. `fail_open=true` so a
  Straiker outage never breaks anyone's coding.
- Add Kong `rate-limiting` per consumer if you want abuse protection (generous — coding
  agents burst).
