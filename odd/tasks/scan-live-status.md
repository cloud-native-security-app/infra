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
| SC-01 | gateway | SSE `keep_alive` (15 s); registry keeps the last event per scan (bounded size, terminal entries expire) and replays it to a new subscriber, then closes if terminal; `failed` after a cancel request is sent as `cancelled`; OpenAPI note; tests | none | [x] 2026-11-18, gateway `25d62d7` |
| SC-02 | infra | ALB `idle_timeout = 300`; terraform test | none | [x] 2026-11-18, infra `67aed8f` |
| SC-03 | front | Cancel button on the scan page (reuses `cancelScan` and its error messages); provider action to mark the scan cancelled; `cancelled` status label; history polling fallback while the stream is down; vitest and Playwright | SC-01 | [x] 2026-11-18, front `6dacd7c` |
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

- 2026-11-18: SC-01 done (route: delegated writer, 7 files, +540/-105; over the 400-line heuristic because `realtime.rs` was rewritten). gateway `feature/scan_sse_resilience` `25d62d7`: SSE keep-alive comment every 15 s (`sse_with_keep_alive`); one `Mutex` holds channels and a last-event cache (1024 scans, terminal entries expire after 15 min, `RealtimeRegistry::with_limits`), so read-last plus subscribe is atomic; a new subscriber gets the last event first and the stream ends if it is terminal; browser-facing `ScanLiveEvent` sends `cancelled` (with `reason`) when the outcome is `failed` after a cancel request; user-service and broker contracts unchanged; D-21. RED: 2 late-subscriber tests failed; GREEN `make verify` exit 0 (parent spot check: realtime 12, relay 10 passed). Review: medium, granted, 1 consolidated lens, approved and acknowledged; suggestions: route-level keep-alive and `from_outcome` matrix tests. Limits: an unknown or expired scan gets nothing (stream stays open); the cancel mark is in memory, so after a gateway restart a cancelled scan shows as `failed`.

- 2026-11-18: SC-03 done (route: delegated writer, 20 files, +855/-35, mostly tests). front `feature/scan_page_cancel` `6dacd7c`: `cancelled` event is terminal and maps to CANCELADO; a terminal status is never overwritten; `markScanCancelled(id)` in the provider, also called from the history table; shared `describeCancelError`; "Cancelar escaneo" button on the scan page; `useScanStatusFallback` polls the history every 5 s while the stream is reconnecting or closed, or after 20 s without events, and stops at a terminal state; mock emits `cancelled` and holds 198.51.100.0/24 targets for e2e. RED: 19 tests failing; GREEN `npm run verify` (Playwright 76 passed; parent spot check: scan tests 112 passed). Review: RDD disabled for front. Gap: the polling fallback is covered by vitest only, not e2e.

- 2026-11-18: gateway CI failed on `consumes_scan_outcomes_from_a_real_queue_and_relays_them_via_sse_in_order_until_terminal_state`: SC-01 rewrote two wire-JSON assertions as raw strings that kept the backslashes (`r#"\"status\":..."#`), so they never matched; the writer's "make verify passed" came from a background run and was wrong. Fixed in gateway `feb389e` (test-only); integration test 3/3 locally, foreground `make verify` exit 0, CI run 44251399868 green.

## Next step

Push the three branches and open PRs (user decision): infra `feature/alb_idle_timeout`, gateway `feature/scan_sse_resilience`, front `feature/scan_page_cancel`, plus this plan. Then SC-04 lab check (deploy gateway before front; `terraform apply` for the ALB idle timeout).
