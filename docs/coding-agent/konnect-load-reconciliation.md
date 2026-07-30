# Enterprise Konnect load + Kong↔Straiker reconciliation

Real Claude-Code-shaped traffic driven through the **enterprise Kong Konnect**
data plane (control plane `straiker-se-demo`, `792fc158-…`) to the Straiker
coding-agent guardrails, reconcilable end-to-end by `session_id`.

## Topology

```
load generator ──HTTP──> Kong Konnect DP (hybrid, :8000) ──> Anthropic /v1/messages
   (X-Straiker-Session-Id)         │  straiker-coding plugin            └─> Bedrock /model/{id}/invoke  (SigV4)
                                   └──> Straiker /api/v1/detect  (x-tool: claude-code)
```

- DP runs in **hybrid mode**, connected to the Konnect CP with the `.env.konnect`
  mTLS cluster cert/key; config (services/routes/plugin) comes from Konnect, the
  plugin code is mounted. Node appears under the CP as
  `792fc158-…:<node>` (`COMPATIBILITY_STATE_FULLY_COMPATIBLE`).
- Bedrock requests are SigV4-signed for the real `bedrock-runtime` host and sent
  to Kong with that `Host`; Kong forwards to the Bedrock upstream and the
  signature validates (Kong doesn't alter signed headers/body).

## Volume — what Kong sees

Konnect Analytics (queried via `POST /v2/api-requests`) recorded, through the DP
under CP `792fc158-…`:

```
Konnect-recorded requests:  4527   (2266 Anthropic /v1/messages  +  2261 Bedrock /model)
```

Both backends well over 1000 requests each. Every request went through the
`straiker-coding` plugin and was scored by Straiker. Tools exercised across the
corpus: Bash, Read, Edit, Write, Grep, TodoWrite, WebFetch, `mcp__github__search_code`.
Hook events synthesized per session: `UserPromptSubmit` + `PreToolUse` +
`PostToolUse` (and a second `PreToolUse` when the follow-up turn calls a tool).

## Reconciliation by session_id

Every request carries `X-Straiker-Session-Id: cc-<backend>-<n>`. The plugin uses
it as the `session_id` it posts to Straiker, so the **same id** links both sides:

- **Kong side**: the DP receives it as a request header and logs one
  `recon sid=<session> event=<E> status=200 turn_id=<T>` line per synthesized
  event (harvested by `konnect/reconcile.py` → `reconciliation.csv`).
- **Straiker side**: each turn is stored under that `session_id` with the
  `turn_id` returned in the detect response.

Sample (`session_id → event:turn_id`), one per tool, both backends:

```
--- anthropic ---
cc-anthropic-00000  Bash       UserPromptSubmit:a42ca021  PreToolUse:e258cab9  PostToolUse:c425d524
cc-anthropic-00001  Read       UserPromptSubmit:1740165e  PreToolUse:6c235ff0  PostToolUse:9ba8a5c3
cc-anthropic-00002  Edit       UserPromptSubmit:3bb72157  PreToolUse:d2fca2b8  PostToolUse:944c6111
cc-anthropic-00005  TodoWrite  UserPromptSubmit:22bbf2ab  PreToolUse:5fb54582  PostToolUse:98931acd  PreToolUse:f30bb260
--- bedrock ---
cc-bedrock-00000    Bash       UserPromptSubmit:5fea4b6e  PreToolUse:929fd8d9  PostToolUse:22ce6e79
cc-bedrock-00001    Read       UserPromptSubmit:742ccee1  PreToolUse:6dd7366c  PostToolUse:6464d131
cc-bedrock-00002    Edit       UserPromptSubmit:042f4d7f  PreToolUse:a5876599  PostToolUse:1e3c10f1
cc-bedrock-00005    TodoWrite  UserPromptSubmit:48807fe0  PreToolUse:bb489d5b  PostToolUse:a0252f52  PreToolUse:7cd1bacf
```

Artifacts (gitignored, in `lab-coding/konnect/out/`):
- `load_reconcile.csv` — every request: session_id, backend, req#, tool, flavor, HTTP status (all 1116 sessions / 2232 requests per run).
- `reconciliation.csv` — session_id → backend → tools → per-event turn_ids (670 sessions / 2151 turns harvested; the rest are in `load_reconcile.csv` + Straiker).

## Where to look

- **Kong (Konnect):** Overview → Analytics, or the Requests explorer, filtered to
  CP `straiker-se-demo` and services `anthropic-coding` / `bedrock-coding`. Shows
  request volume, status, and latency (Kong-gateway vs upstream) per route.
  `https://cloud.konghq.com/us/analytics/requests`
- **Straiker:** the **Claude Code through Kong** app
  (`dapp_E2GkIaZn8AT`) coding-agents card — turns grouped by `session_id`, each
  with its detection verdict.

To surface `session_id` **directly** in the Konnect request explorer (rather than
via the reconciliation table), append it to the request path as a query param
(`/v1/messages?sid=<session_id>`) — Kong ignores the query for routing but records
it in `request_uri`. (Not used for the Bedrock leg, whose URL is SigV4-signed.)

## Reproduce

```bash
set -a && source .env.konnect && source lab-coding/.env && set +a
python3 lab-coding/konnect/setup_cp.py        # register schema + services/routes/plugins on the CP
lab-coding/konnect/run_dp.sh                   # start the Konnect-connected data plane
STRAIKER_CODING_KEY=… ANTHROPIC_API_KEY=… \
  python3 lab-coding/konnect/generate_load.py --backend both --min 1100 --workers 12
python3 lab-coding/konnect/reconcile.py --since <ts>   # session_id <-> turn_id table
```
