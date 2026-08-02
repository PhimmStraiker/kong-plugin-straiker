# Konnect cost model — what actually bills (verified from a real invoice)

**Kong Konnect bills per CONTROL PLANE per hour. Not per request, not per service, not per
data plane node.** Getting this wrong is expensive, so the numbers below come from the
July 2026 invoice, not from docs.

## July 2026 invoice: $433.70

| Line | Qty | Unit | Total |
|---|---|---|---|
| Control Planes — **Self Managed** | **1,488 hrs** | $0.273972/hr | **$407.67** (94%) |
| Control Planes — Serverless | 744 hrs | $0.034246/hr | $25.48 |
| **API Requests** | **7,954** | Tier 1 (0–1M) | **$0.00** |
| AI Gateway Models | 4 hrs | $0.136986/hr | $0.55 |

1,488 hrs = **2 control planes × 744 hrs** (31 days × 24) — billed for every hour they
*existed*, with near-zero traffic.

## The rules that follow

- **Self-managed (hybrid) control plane ≈ $204/month** ($0.273972/hr × 730). This is the
  meter. It bills whether or not any traffic flows.
- **Serverless control plane ≈ $25/month.**
- **Requests are effectively free at our scale** — 1M/month included, then tiered. We used
  7,954 (0.8%). *Adoption does not drive cost; existence does.* Onboarding every SE costs
  nothing; leaving a control plane lying around costs $204/month.
- **Gateway services, routes, and self-hosted data plane nodes are $0.** Consolidating
  services saves nothing. (Learned the hard way — a service consolidation was done for
  "cost" and saved $0. It's fine architecture, not a cost lever.)
- Metering is **hourly and prorated**, so deleting stops the meter immediately, and a
  mid-month delete bills only for hours elapsed. Billing is in arrears.

## Operating rule: no idle control planes

A control plane is the unit of spend, so the only discipline that matters is: **delete a
control plane when the work it served is finished.** One per active workstream, zero
leftovers. Spinning one up "for isolation" is a **$204/month** decision — make it
deliberately.

## Cleanup performed 2026-08-02 ($625 → $408/month)

Deleted (idle):
- `iqvia-poc` — engagement over, 0 nodes, 0 traffic — **$204/mo**
- `serverless-api-gateway-demo` — Kong-hosted, unused — **$25/mo**
- `straiker-demo` — empty control-plane group — $0

Kept (both actively used):
- `straiker-se-demo` — plugin development + lab (local Docker DP, file-log capture)
- `straiker-shared-kong-gateway` — the shared SE gateway behind `konggw.dev.straiker.ai`

Verified after cleanup: real Claude Code through the shared gateway returns normally, the
local lab DP is still connected, golden regression suite 19/19.

## Other idle spend to watch (AWS, not Kong)

The App Runner data plane bills for **provisioned memory even when idle** (~$10/month at
2 GB) plus active compute only while serving. It must stay up to serve SEs on demand, so
this is availability cost rather than waste — but it is the other thing that runs 24/7.

## Where to look

- Konnect → **Organization → Plan and usage → Invoices** (authoritative, itemized).
- `GET https://global.api.konghq.com/kbilling/v1/usage` (global host only; `us.`/`eu.`
  return 404) — quantities only, no dollar amounts. There is **no** billing API and **no**
  spend cap; billing notifications to org admins are the only guardrail.
