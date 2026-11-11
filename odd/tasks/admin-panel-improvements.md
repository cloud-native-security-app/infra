# Feature: admin-panel-improvements

Master plan for the work after `v3` on the Kinesis admin panel. Each task lives in its own repo and branch. Predecessor: `odd/tasks/kinesis-admin-panel.md` (KAP-00..KAP-11, released as `v3`).

## Objective

Make the admin panel usable under real event volume, add charts of the event stream, and close the follow-ups left by the KAP plan.

## Problem

Found by the user on the `v3` deploy (2026-11-11), plus the follow-ups recorded in the KAP plan:

1. Logged in as admin, the header nav breaks, probably for lack of space: the admin link ("Administración") is a fourth link next to the user block.
2. The panel grows without bound. The event log renders up to 100 rows and the scans-in-flight list up to 1000 rows, with no max height, scrolling, or pagination (`front/src/features/admin/adminReducer.ts:9-11`, `EventLog.tsx`, `admin.css`).
3. The user wants charts of the event stream. The admin API only exposes counters (`gateway/src/admin.rs` `Kpis`, `AdminSnapshot`, `AdminDelta`), and the front has no chart library.
4. After a gateway restart the panel is empty: the consumer starts at `LATEST` with no checkpoint (`gateway/src/kinesis_consumer.rs:335-341`).
5. If the admin role is revoked mid-session, the nav link and `/admin` stay until a reload. The role comes from `GET /api/me`, read once in `SessionProvider.tsx:49`; the `forbidden` branch of `useAdminFeed.ts` never tells the session.
6. A failed `PutRecord` drops the event: `emit` spawns one attempt with a 5 s timeout and only logs the error, and `emit_all` drops the rest of the batch on the first failure (gateway, nmap-service, user-service `src/security_events.rs`).

## Decisions

- Charts are hand-written inline SVG React components, no chart library. Reason: the panel needs three or four simple shapes (stacked bars per minute, line, bar), the front has no dependency for it today, and own components keep theme tokens (light and dark), accessibility (a data table alternative) and bundle size under control. Revisit only if a later chart needs zoom or brushing.
- The gateway builds the time series. Reason: the front only keeps the last 100 events, so it cannot derive real per-minute rates. The snapshot carries per-minute buckets by `event_type`; each delta already carries its event, so the front increments the current bucket locally.
- Window buckets use the event's `occurred_at`, not ingest time. Required by the warm start (replayed events must land in their minute) and by the charts.
- Warm start: on the first shard iterator only, the consumer uses `AT_TIMESTAMP` at `now - WINDOW_SECS` (15 min). Expired-iterator recovery keeps `LATEST`. The existing `event_id` dedupe (2048) absorbs overlap. No checkpoint store (DynamoDB or S3): out of scope for a lab.
- Producer reliability: bounded in-memory retry with exponential backoff and jitter, inside the existing 5 s budget, and `emit_all` keeps publishing the rest of the batch after a failure. A durable outbox is rejected for now: the gateway has no database, and it would need a table plus a relay in each service. Events stay best-effort and never fail the business operation.
- Role loss: `SessionProvider` exposes `refresh()`; the admin feed calls it on `forbidden`, so `AppHeader` and `AdminRoute` update without a reload.

## Constraints

- Strict TDD (user global config): RED before GREEN in every task.
- The admin API is internal to gateway and front; the broker event contract does not change. Any new admin payload field goes to the gateway OpenAPI (utoipa) and to the front guards (`front/src/api/adminGuards.ts`) and contract-server mock.
- Artifacts in English, Conventional Commits, no attribution.
- One branch per task, cut from `develop`; PRs target `develop` (the GitHub default branch is still `main` in gateway, nmap-service and infra).

## Tooling

- Runners: front `npm run verify` and Playwright; Rust services `make verify`; infra `make verify`.
- Review: per stored user policy, decline reviews except tasks touching permissions or secrets (none of these tasks changes authorization; review on request).

## Checklist

| ID | Repo | Task | Depends on | Done |
|---|---|---|---|---|
| AP-01 | front | Reproduce the admin nav break with Playwright as admin at 1280, 1024, 768 and 375 px (RED), fix the header CSS so four links plus the user block fit or wrap cleanly, keep the existing header specs green | none | [ ] |
| AP-02 | front | Bound the panel: event log and scans-in-flight in fixed-height scroll regions with sticky headers; scans list shows the newest N with a "N more" count; a pause/resume control for the live log; reducer unit tests (vitest) for the caps | none | [ ] |
| AP-03 | front | `SessionProvider.refresh()`; `useAdminFeed` calls it on `forbidden`; nav link and `/admin` disappear without reload; Playwright spec with the contract-server revoking the role | none | [ ] |
| AP-04 | gateway | Window buckets by `occurred_at`; consumer warm start with `AT_TIMESTAMP now-15min` on the first iterator (`RecordsSource` gains an at-timestamp iterator); unit tests with the fake source and the LocalStack test | none | [ ] |
| AP-05 | gateway | Time series: per-minute buckets by `event_type` for the last 15 minutes in `AdminSnapshot.series`; OpenAPI; unit tests | AP-04 | [ ] |
| AP-06 | front | Charts: events per minute stacked by type, scans completed vs failed per minute, findings by severity; inline SVG, theme tokens, table alternative for screen readers; series guard and contract-server mock; Playwright spec | AP-02, AP-05 | [ ] |
| AP-07a | gateway | Producer retry with backoff and jitter within 5 s; `emit_all` continues after a failure; tests with a failing publisher | none | [ ] |
| AP-07b | nmap-service | Same as AP-07a | none | [ ] |
| AP-07c | user-service | Same as AP-07a | none | [ ] |

Order: AP-01, AP-02 and AP-03 first (visible bugs, front only), then AP-04 and AP-05, then AP-06, and AP-07a..c at any point. None of them needs a lab session; a final deploy check can follow under the usual release flow.

## Branches

| Task | Repo | Branch |
|---|---|---|
| AP-01 | front | `fix/admin_nav_overflow` |
| AP-02 | front | `feature/admin_bounded_panel` |
| AP-03 | front | `feature/session_role_refresh` |
| AP-04 | gateway | `feature/consumer_warm_start` |
| AP-05 | gateway | `feature/admin_time_series` |
| AP-06 | front | `feature/admin_charts` |
| AP-07a | gateway | `feature/event_publish_retry` |
| AP-07b | nmap-service | `feature/event_publish_retry` |
| AP-07c | user-service | `feature/event_publish_retry` |

## Acceptance criteria

- As admin, the header shows every link and the user block without overlap at 375, 768, 1024 and 1280 px.
- Under a burst of events the admin page height stays constant; the log scrolls inside its region and can be paused.
- The panel shows per-minute charts that move live and survive a gateway restart (the last 15 minutes come back).
- Revoking the admin role hides the nav link and leaves `/admin` within one gateway re-check (60 s), without a reload.
- A transient Kinesis failure is retried; a persistent one is logged and never fails the business operation.

## Out of scope

- Durable outbox and consumer checkpoints.
- Chart zoom, brushing or ranges longer than the 15-minute window.
- Abuse detection rules and Firehose archive (still KAP follow-ups).

## Progress

- 2026-11-11: plan written from the user's report on the `v3` deploy and the KAP follow-ups.

## Next step

AP-01 on `fix/admin_nav_overflow` in front.
