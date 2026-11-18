# Scan page live status and cancel button

## Objective

The scan page shows the real state of the current scan (running, completed, failed, cancelled) without getting stuck in "loading" or "sin conexión", and lets the user cancel the running scan from that page.

## Problem

Observed in the lab on 2026-11-17:

1. The ALB closes the SSE stream after 60 s of silence because the gateway sends no keep-alive; a scan takes about 2 minutes.
2. When the browser reconnects, the gateway does not replay the current state; a terminal event published during the gap is lost and the page loads forever.
3. A cancelled scan reaches the browser as `failed` (nmap-service reports a cancellation as failed), so the page shows "Falló".
4. Cancel exists only in the history table, and cancelling there does not update the scan page.

## Scope

- gateway: SSE keep-alive comments; the registry keeps the last event of each scan (bounded) and a new subscriber gets it first; when the outcome is `failed` and a cancel was requested for that scan, the browser receives `cancelled`; tests.
- infra: ALB `idle_timeout` 300 s, as defence in depth; test.
- front: "Cancelar escaneo" button on the scan page while the scan runs; cancelling updates the page state; `cancelled` status shown as "Cancelado"; when the stream is reconnecting or closed and the scan is not terminal, poll the history for the scan status and stop polling at a terminal state; tests.

## Constraints

- Strict TDD (session config). Runners: `make verify` (gateway, infra), `npm run verify` (front).
- The SSE event shape stays backward compatible: same JSON, one more `status` value (`cancelled`).
- The last-event cache is bounded in size and age so it cannot grow without limit.
- Deploy the gateway before the front.

## Tasks

| ID | Repo | Task | Depends on | Done |
|---|---|---|---|---|
| SC-01 | gateway | SSE `keep_alive` (15 s); registry keeps the last event per scan (bounded size, terminal entries expire) and replays it to a new subscriber, then closes if terminal; `failed` after a cancel request is sent as `cancelled`; OpenAPI note; tests | none | [ ] |
| SC-02 | infra | ALB `idle_timeout = 300`; terraform test | none | [x] 2026-11-18, infra `67aed8f` |
| SC-03 | front | Cancel button on the scan page (reuses `cancelScan` and its error messages); provider action to mark the scan cancelled; `cancelled` status label; history polling fallback while the stream is down; vitest and Playwright | SC-01 | [ ] |
| SC-04 | infra | Lab deploy and check: a scan that outlives 60 s finishes on the page; cancel from the scan page shows "Cancelado"; reload during a scan shows the current state | SC-01..SC-03 | [ ] |

## Branches

| Task | Repo | Branch |
|---|---|---|
| SC-01 | gateway | `feature/scan_sse_resilience` |
| SC-02 | infra | `feature/alb_idle_timeout` |
| SC-03 | front | `feature/scan_page_cancel` |
| SC-04 | infra | lab check, no branch unless fixes are needed |
| plan | infra | `docs/scan_live_status_plan` |

## Acceptance criteria

- A 2-minute scan ends on the scan page as completed, with no "sin conexión" left on screen.
- Reloading the page or reconnecting during a scan shows its current state at once.
- Cancelling from the scan page or the history shows "Cancelado" on the scan page.
- With the stream down, the page still reaches the final state through history polling.

## Delivery

Forecast about 800 authored changed lines: gateway about 350, front about 400, infra about 20. One PR per repo. Strategy: `ask-on-risk`.

## Progress

- 2026-11-18: plan created from the 2026-11-17 mapping (gateway `api.rs` `scan_events` without keep-alive, `realtime.rs` drops events with no receiver and has no replay; front `useScanEvents.ts`, `ScanForm.tsx`, cancel only in `HistoryTable.tsx`; ALB without `idle_timeout`). User asked to implement it.

- 2026-11-18: SC-02 done (route: inline, 2 files). infra `feature/alb_idle_timeout` `67aed8f`: `aws_lb.main.idle_timeout = 300` and an assertion in `alb.tftest.hcl`. RED: assertion failed; GREEN: `make verify` 71 passed. Review: medium, under budget.

## Next step

SC-01 (gateway, delegated writer in progress), then SC-03.
