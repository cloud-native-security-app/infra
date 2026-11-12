# Feature: admin-panel-improvements

Master plan for the work after `v3` on the Kinesis admin panel. Each task lives in its own repo and branch. Predecessor: `odd/tasks/kinesis-admin-panel.md` (KAP-00..KAP-11, released as `v3`).

## Objective

Move the event-stream read side out of the gateway into a new `events-service`, make the admin panel usable under real event volume, add charts of the event stream, and close the follow-ups left by the KAP plan.

## Problem

Found by the user on the `v3` deploy (2026-11-11), plus the follow-ups recorded in the KAP plan:

1. Logged in as admin, the header nav breaks, probably for lack of space: the admin link ("Administración") is a fourth link next to the user block.
2. The panel grows without bound. The event log renders up to 100 rows and the scans-in-flight list up to 1000 rows, with no max height, scrolling, or pagination (`front/src/features/admin/adminReducer.ts:9-11`, `EventLog.tsx`, `admin.css`).
3. The user wants charts of the event stream. The admin API only exposes counters (`gateway/src/admin.rs` `Kpis`, `AdminSnapshot`, `AdminDelta`), and the front has no chart library.
4. After a gateway restart the panel is empty: the consumer starts at `LATEST` with no checkpoint (`gateway/src/kinesis_consumer.rs:335-341`).
5. If the admin role is revoked mid-session, the nav link and `/admin` stay until a reload. The role comes from `GET /api/me`, read once in `SessionProvider.tsx:49`; the `forbidden` branch of `useAdminFeed.ts` never tells the session.
6. A failed `PutRecord` drops the event: `emit` spawns one attempt with a 5 s timeout and only logs the error, and `emit_all` drops the rest of the batch on the first failure (gateway, nmap-service, user-service `src/security_events.rs`).
7. The gateway (API Manager: OIDC, session, rate limit, routing) also hosts the Kinesis consumer and the admin aggregator. Charts and warm start would add time series, replay and dedupe to it. A bug there takes down login and scans; each gateway instance is a full stream reader, so scaling HTTP also multiplies readers on a shard limited to 5 `GetRecords` per second shared by all consumers; and every panel change redeploys the entry point.

## Decisions

- **New `events-service` (user decision 2026-11-11).** It owns the read side of the stream: Kinesis consumer, aggregator, time series and the admin SSE. It replaces the KAP decision "the gateway consumes Kinesis directly, no extra service". Rust/axum, same layout and conventions as user-service (hexagonal, `make verify`, CI and deploy workflows).
- **The gateway stays the only entry point.** It keeps the session, `require_admin` (re-validated against user-service) and the 60 s role re-check on the SSE stream, and proxies `GET /api/admin/metrics` and `GET /api/admin/events` to events-service. The public API, its OpenAPI and the front URLs do not change.
- **Service-to-service auth.** events-service is internal only (Service Connect, no ALB target group) and requires a shared secret header from the gateway, the same pattern as gateway to user-service (`MS_USUARIOS_SHARED_SECRET` / `GATEWAY_SHARED_SECRET`). The admin identity is not forwarded: authorization stays in the gateway.
- **Producers do not change.** gateway, nmap-service and user-service keep publishing to `security-events`. Only the gateway's consumer and aggregator move.
- **Move first, then extend.** The extraction (ES-02, ES-03) keeps behavior identical; warm start, series and charts land afterwards in events-service, so no code is written twice.
- **Charts** are hand-written inline SVG React components, no chart library: three simple shapes, theme tokens (light and dark), a data table alternative for screen readers, no new dependency. Revisit only if a chart needs zoom or brushing.
- **events-service builds the time series**: 15 one-minute buckets, counts by `event_type`, plus `finding.critical` by severity. The snapshot carries the series; deltas already carry their event, so the front adds +1 to the bucket of its `occurred_at` and rotates the window every minute. A reconnect brings a fresh snapshot.
- **Buckets use `occurred_at`, not ingest time**, so replayed and late events land in their real minute. Events older than the window are neither counted nor bucketed (as built in AP-04: window KPIs use `occurred_at` too); future timestamps (clock skew) clamp to the current minute.
- **Warm start**: on the first shard iterator only, the consumer uses `AT_TIMESTAMP` at `now - 15 min`. Expired-iterator recovery keeps `LATEST`. The `event_id` dedupe absorbs overlap. No checkpoint store (DynamoDB or S3).
- **Producer reliability**: bounded in-memory retry with exponential backoff and jitter inside the existing 5 s budget; `emit_all` keeps publishing after a failure. A durable outbox is rejected for now (the gateway has no database; it needs a table and a relay per service). Events stay best-effort and never fail the business operation.
- **Role loss in the front**: `SessionProvider` exposes `refresh()`; the admin feed calls it on `forbidden`, so `AppHeader` and `AdminRoute` update without a reload.

## Constraints

- Strict TDD (user global config): RED before GREEN in every task.
- The broker event contract does not change. events-service validates parsed events against `../broker/contracts/security-event.schema.json` like the gateway does today (`event_contract.rs` moves with the consumer).
- New admin payload fields go to the OpenAPI, the front guards (`front/src/api/adminGuards.ts`) and the contract-server mock.
- Learner Lab: events-service runs as `LabRole`, which reads Kinesis from Fargate (KAP-00b). One more Fargate task costs lab credit.
- Artifacts in English, Conventional Commits, no attribution.
- One branch per task, cut from `develop`; PRs target `develop` (the GitHub default branch is still `main` in gateway, nmap-service and infra).

## Tooling

- Runners: front `npm run verify` and Playwright; Rust services `make verify`; infra `make verify`.
- Review: per stored user policy, decline reviews except tasks touching permissions or secrets: ES-01 (shared-secret auth), ES-03 (admin proxy behind `require_admin`), ES-04 (new SSM secret and service wiring).

## Checklist

| ID | Repo | Task | Depends on | Done |
|---|---|---|---|---|
| AP-01 | front | Reproduce the admin nav break with Playwright as admin at 1280, 1024, 768 and 375 px (RED), fix the header CSS so four links plus the user block fit or wrap cleanly, keep the existing header specs green | none | [x] front #29 (two-row nav), superseded by AP-01b |
| AP-02 | front | Bound the panel: event log and scans-in-flight in fixed-height scroll regions with sticky headers; scans list shows the newest N with a "N more" count; pause/resume for the live log; reducer unit tests (vitest) for the caps | none | [x] front #31 |
| AP-03 | front | `SessionProvider.refresh()`; `useAdminFeed` calls it on `forbidden`; nav link and `/admin` disappear without reload; Playwright spec with the contract-server revoking the role | none | [x] front #32 |
| ES-00 | GitHub | User creates the `cloud-native-security-app/events-service` repo with `main` and `develop`, and adds it to the AWS secrets refresh | none | [x] repo created |
| ES-01 | events-service | Scaffold: axum app, config, `/health`, shared-secret middleware, Dockerfile, Makefile `verify`, CI and deploy workflows (user-service pattern), README; decision record (broker `docs/decisions.md`) | ES-00 | [x] events-service #1 |
| ES-02 | events-service | Move the Kinesis consumer, aggregator, event contract validator and `GET /metrics` + `GET /events` (SSE snapshot then deltas) from the gateway, same behavior and payloads; move their unit tests and the LocalStack round-trip test | ES-01 | [x] events-service #2 |
| ES-03 | gateway | Replace the in-process consumer and aggregator with a proxy to events-service: metrics forward, SSE stream pass-through with the 60 s role re-check still injecting `closed`, shared secret header, 503 when events-service is unreachable; delete the moved code; OpenAPI unchanged | ES-02 | [x] gateway #31 |
| ES-04 | infra | events-service: ECR repo, ECS service (Service Connect publish, no target group, `LabRole`), SSM shared secret, env (`SECURITY_EVENTS_STREAM_NAME`, `AWS_REGION`); gateway env `EVENTS_SERVICE_BASE_URL` + secret; compose service; `push-images.sh`, `refresh-gh-secrets.sh`, `verify-stack.sh`; tests | ES-01 | [x] infra #31 |
| AP-04 | events-service | Buckets by `occurred_at`; warm start with `AT_TIMESTAMP now-15min` on the first iterator (`RecordsSource` gains an at-timestamp iterator); unit tests with the fake source and the LocalStack test | ES-02 | [x] events-service #3 |
| AP-05 | events-service | Time series in the snapshot: 15 one-minute buckets by `event_type` and `finding.critical` by severity; OpenAPI; unit tests with the injected clock | AP-04 | [x] events-service #4, gateway #33 (OpenAPI) |
| AP-06 | front | Charts: events per minute stacked by type, scans completed vs failed per minute, findings by severity; reducer applies snapshot series, +1 per delta and a one-minute window tick; pure scale functions (vitest); inline SVG with theme tokens and a table alternative; redraw at most once per frame; series guard and contract-server mock; Playwright spec | AP-02, AP-05 | [x] front #33 |
| AP-01b | front | User decision 2026-11-11: replace the two-row nav with a hamburger user menu (identity, theme toggle, logout; links move into it below 640 px) | AP-01 | [x] front #30 |
| AP-07a | gateway | Producer retry with backoff and jitter within 5 s; `emit_all` continues after a failure; tests with a failing publisher | none | [x] gateway #34 |
| AP-07b | nmap-service | Same as AP-07a | none | [x] nmap-service #29 |
| AP-07c | user-service | Same as AP-07a | none | [x] user-service #13 |
| AP-08 | front | Fix: an open chart table widened its card and scaled the plot over its neighbours (card column `minmax(0, 1fr)`); then, user request 2026-11-12, an open table makes its card span the full row so the other charts move down; plot keeps a max width; Playwright spec | AP-06 | [ ] fix committed `200c56a` |
| AP-09 | front | Events-per-minute chart excludes `finding.critical` (it has its own chart and swamped "Otros"); unit tests for the fold | AP-06 | [ ] |
| AP-10 | front | Horizontal tabs (WAI-ARIA tabs pattern) for scans in flight, critical findings and event log below the charts; each panel keeps its scroll region and the log keeps pause; a tab shows an unseen-items count that clears when opened; vitest and Playwright (keyboard, axe) | AP-02 | [ ] |

Order:

1. AP-01, AP-02 and AP-03 (visible bugs, front only, independent of the extraction).
2. ES-00, ES-01, ES-02, then ES-04 and ES-03. The cutover (ES-03) merges last, so `develop` never points the gateway at a service that does not exist.
3. AP-04 and AP-05 in events-service, then AP-06 in the front.
4. AP-07a..c at any point.
5. AP-08, AP-09 and AP-10 (feedback from the lab check, 2026-11-12).

A lab deploy and check closes the plan, like KAP-11.

## Branches

| Task | Repo | Branch |
|---|---|---|
| AP-01 | front | `fix/admin_nav_overflow` |
| AP-02 | front | `feature/admin_bounded_panel` |
| AP-03 | front | `feature/session_role_refresh` |
| ES-01 | events-service | `feature/scaffold` |
| ES-02 | events-service | `feature/move_admin_feed` |
| ES-03 | gateway | `feature/admin_feed_proxy` |
| ES-04 | infra | `feature/events_service` |
| AP-04 | events-service | `feature/consumer_warm_start` |
| AP-05 | events-service | `feature/admin_time_series` |
| AP-06 | front | `feature/admin_charts` |
| AP-01b | front | `feature/header_user_menu` |
| AP-07a | gateway | `feature/event_publish_retry` |
| AP-07b | nmap-service | `feature/event_publish_retry` |
| AP-07c | user-service | `feature/event_publish_retry` |
| AP-08 | front | `fix/admin_chart_table_overflow` |
| AP-09 | front | `fix/events_chart_without_findings` |
| AP-10 | front | `feature/admin_panel_tabs` |

## Acceptance criteria

- As admin, the header shows every link and the user block without overlap at 375, 768, 1024 and 1280 px.
- Under a burst of events the admin page height stays constant; the log scrolls inside its region and can be paused.
- After the extraction the panel behaves as in `v3` through the gateway; events-service is not reachable from the internet and rejects requests without the shared secret.
- Stopping events-service does not affect login or scans; `/api/admin/*` answers 503.
- Opening a chart table never overlaps other charts; the open card takes the full row.
- Critical findings appear only in their own chart, not in "Otros".
- Scans in flight, critical findings and the event log are tabs; a hidden tab shows how many new items arrived.
- The panel shows per-minute charts that move live and survive a restart of events-service (the last 15 minutes come back).
- Revoking the admin role hides the nav link and leaves `/admin` within one gateway re-check (60 s), without a reload.
- A transient Kinesis failure is retried; a persistent one is logged and never fails the business operation.

## Out of scope

- Durable outbox and consumer checkpoints.
- Chart zoom, brushing or ranges longer than the 15-minute window.
- Abuse detection rules and Firehose archive (still KAP follow-ups).

## Progress

- 2026-11-11: plan written from the user's report on the `v3` deploy and the KAP follow-ups.
- 2026-11-11: reorganized (user decision): the read side moves to a new `events-service`; tasks ES-00..ES-04 added before the warm start, series and charts.

- 2026-11-11..12: AP-01..AP-07c merged to `develop` (PR numbers in the checklist). AP-01b added by user decision (hamburger menu instead of the two-row nav).
- 2026-11-12: lab deploy check. `terraform apply` created events-service (8 resources) and gateway task definition revision 2 with `EVENTS_SERVICE_*`; images pushed (events-service first); all ECS services 1/1; `scripts/verify-stack.sh` 11 passed, 0 failed. The user confirmed the charts move live and reported two issues: an open table breaks the chart layout, and "Otros" is swamped by critical findings. Added AP-08..AP-10 (tabs chosen over a sidebar by the user).

## Next step

AP-08 (table layout) on `fix/admin_chart_table_overflow`, then AP-09 and AP-10 in front. Then a lab redeploy of front.
