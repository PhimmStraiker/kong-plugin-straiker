# Final assistant response: gateway sends it, backend must persist + display it

## Empirical status (from the prod Defend export, not code reading)

The user exported the full Defend activity CSV for the app. Ground truth:

- The gateway **is** sending the final response. Kong's file-log shows the `Stop`
  event with `app_response = "The config.yaml shows team_a quota is 1000 and
  team_b quota is 2500."` posted to `/api/v1/detect` (HTTP 200, turn_id returned).
- **Straiker is NOT storing it.** In the export, session `edf9d5ee` (the Stop
  test) has 6 rows, and **every** `user_interaction_record` shows
  `app_response=null` — including the final Stop turn. Across all 6,232 turns in
  the export, `app_response` is null everywhere.

So the final assistant response is **not captured in Straiker today**, even though
the gateway delivers it. This is a backend gap, and it must be fixed backend-side;
the gateway half is done.

> Correction: earlier I claimed the response was stored (because
> `create_turn_from_payload` maps `payload.app_response → turn.app_response` in the
> argus clone at `core/turn.py:86`, and `archive.py:41` archives it). The prod
> export disproves that — `app_response` lands as null for coding-agent turns.
> Either prod differs from the local clone (HEAD 2026-05-16) or the coding path
> drops it before archival. Engineering owns finding the exact spot; the export is
> the authority.

## What the gateway sends (verified)

```json
{ "hook_event_name": "Stop",
  "app_response": "<the model's final answer, verbatim from the wire>",
  "stop_reason": "end_turn",
  "session_id": "<claude code session uuid>",
  "user_name": "<identity>" }
```

## What the backend needs to do

1. **Persist** `app_response` for coding-agent `Stop` events. Expected path:
   `DetectAPIRequest(**body)` parses `app_response` (declared field, `api.py:46`) →
   `create_turn_from_payload` sets `turn.app_response` (`turn.py:86`) →
   `archive_turn` writes it (`archive.py:41,43`). The prod export shows null, so
   one of these is not happening on the coding path in prod — investigate + fix.
2. **Display** it in Activity. The Stop handler
   (`coding_tools/hook_dispatcher.py:287-289`) appends the event to the trace but
   never sets `turn.context["current_event"]` (unlike PostToolUse at line 259), and
   `extract_attributes` doesn't pull `app_response`. So even once stored it won't
   render. Minimal edits:
   - `event_attribute_extractor.extract_attributes`: for `event in ("Stop","stop")`
     return `{"app_response": (hook_data.get("app_response") or "")[:2000]}`.
   - `hook_dispatcher.py` Stop branch: add `turn.context["current_event"] = entry`.

## Why it matters (the pitch, unchanged)

The native Claude Code `Stop` hook **does not include the final assistant
response** — so today the agent's answer never reaches Straiker for any coding
agent. The **gateway sees the full response on the wire** and already delivers it.
Closing the backend gap (persist + display) unlocks output-side visibility and,
later, output guardrails (PII/secret/exfil scanning of the model's answer) that the
endpoint hook fundamentally cannot provide. This is the concrete advantage of the
gateway approach — the data is now arriving; the backend needs to keep it.
