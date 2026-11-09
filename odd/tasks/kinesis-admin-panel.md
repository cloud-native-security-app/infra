# Feature: kinesis-admin-panel

Master plan for the Kinesis event stream and the real-time admin panel (cross-repo, like `odd/tasks/cloud-native-deploy.md`).
Engram topic for this doc: `odd/kinesis-admin-panel/tasks` (project: infra). Branch: `feature/kinesis_admin_plan` (from `origin/develop` 9a57355).
Release line: `v2` is the snapshot of everything delivered before this feature (cut 2026-11-02 in all six repos). This feature lands on `develop` and ships as `v3`.

## Objective

Services publish immutable domain events to an AWS Kinesis Data Stream (`security-events`). The gateway consumes the stream and serves an admin-only, real-time panel in the front.

## Problem

- Real-time data lives in the gateway's in-memory `RealtimeRegistry` (`gateway/src/realtime.rs`), one channel per scan, local to one instance. There is no cross-scan or cross-instance view.
- There is no role concept: the user model only has `sub`, `email`, and name.
- Operational signals (failed scans, critical findings, rate-limit hits, dead-lettered messages) are only visible in CloudWatch logs.

## Why

An ordered, replayable event log lets several consumers (admin panel now; abuse detection and archive later) read the same facts without coupling producers to them.

## Decisions

- SNS+SQS stays for commands (scan request and cancellation). Kinesis carries domain facts only. Kafka/MSK stays rejected (`broker/docs/decisions.md`).
- Admin role is a `users.role` column in user-service (user decision 2026-11-02), bootstrapped from `ADMIN_BOOTSTRAP_EMAILS`. The gateway puts it in its JWT as a `role` claim.
- The gateway consumes Kinesis directly with `GetShardIterator(LATEST)` + `GetRecords` per shard. No KCL and no extra service. Every gateway instance reads every event.
- Stream: PROVISIONED, 1 shard, 24h retention. Partition key: `scan_id`, else `actor_sub`.
- Each producer depends on a `SecurityEventPublisher` port, with a Kinesis adapter and an in-memory adapter for tests. A Kinesis failure is logged and never fails the business operation.

## Event contract

`broker/contracts/security-event.schema.json`. Envelope: `event_id` (UUID), `event_type`, `occurred_at` (RFC 3339), `source`, `actor_sub?`, `scan_id?`, `payload`.

| `event_type` | Producer | Payload |
|---|---|---|
| `scan.requested`, `scan.cancelled` | gateway | target, requester |
| `scan.started`, `scan.completed`, `scan.failed` | nmap-service | duration, counts, failure reason |
| `finding.critical` | nmap-service | port, CVE, severity (high/critical), confidence |
| `auth.login`, `auth.logout` | gateway | none beyond envelope |
| `ratelimit.hit` | gateway | route, limit |
| `message.deadlettered` | gateway | queue, reason (no message body) |
| `audit.recorded` | user-service | action, resource type (no secrets) |

## Constraints

- Learner Lab: every resource uses `LabRole`. Kinesis Data Streams works from the lab CLI session (KAP-00, 2026-11-09); access as `LabRole` from an ECS task is still unverified (KAP-00b). If it is denied, keep the port and ship an SNS fan-out adapter instead.
- Events never carry credentials, tokens, raw scan output, or message bodies.
- No service depends on the broker crate, so each producer (KAP-06/07/08) and the consumer (KAP-09) keep their own envelope type. Their tests MUST validate every emitted or parsed event against `../broker/contracts/security-event.schema.json` and the examples in `../broker/contracts/examples/security-event/` (sibling-path pattern of broker `tests/topology_parity.rs`), so a schema change breaks their build instead of drifting silently.
- Local runs use LocalStack 4.4 with `kinesis` enabled and the same stream name.
- Artifacts in English; START.md in neutral Spanish. Conventional Commits, no attribution.

## Tooling

- TDD mode: on (source: user global config "Strict TDD Mode: enabled").
- Runners: Rust services `make verify`; front `npm run verify`; infra `make verify`, `terraform test`, `bash scripts/test-localstack-init.sh`; broker `cargo test`.
- Route: one delegated writer per task, one repo per task.
- Review: `gentle-ai review assess` after each work-unit commit. Per stored user policy, decline reviews except tasks touching permissions or secrets: KAP-01 (IAM/stream access), KAP-04 (role bootstrap), KAP-05 (admin authorization).

## Checklist

| ID | Repo | Task | Depends on | Done |
|---|---|---|---|---|
| KAP-00 | infra | Spike: create, describe, put, get, and delete a 1-shard stream from the Learner Lab CLI session; record result. **Result 2026-11-09: YES.** `create-stream` reached `ACTIVE` with 1 open shard, `put-record` returned a sequence number, `get-records` (TRIM_HORIZON) returned the record, `delete-stream` succeeded. Gotcha: the local AWS CLI is v1, so `--cli-binary-format` is unknown and `--data` is sent as raw text. | none | [x] 2026-11-09 |
| KAP-00b | infra | Spike: same put/get as `LabRole` from a Fargate task (MSG-02 pattern: `public.ecr.aws/aws-cli/aws-cli`, task and execution role `LabRole`); record result or fallback | KAP-00 | [ ] needs a lab session |
| KAP-01 | infra | `terraform/streaming.tf` stream + SSM name + ECS env wiring; `.tftest.hcl` (RED first) | KAP-00b | [ ] |
| KAP-02 | infra | LocalStack: enable `kinesis`, create `security-events` in the init script, extend its offline test; START.md section B | none | [ ] |
| KAP-02b | broker | Close the v2 leftover `odd/tasks/sqs-sns-migration.md` MSG-03..MSG-09 before adding the new contract: first reconcile each item against what infra already delivered (LocalStack compose, TF-10 topology) and tick what is covered with evidence; then finish the rest (contract, DLQ, and encryption tests on LocalStack; parameter hand-off; retire `rabbitmq/`, AMQP test code, and `lapin`/testcontainers-rabbitmq). Mark `amazon-mq-migration.md` as superseded. **Done 2026-11-09** on `feature/retire_rabbitmq` (0509ac1, 8c09e62, ee1aaa4, 1ff2fab; not pushed): MSG-03 ticked by reconciliation (infra LocalStack), MSG-04..07 LocalStack tests, MSG-08 offline parity test vs `../infra`, MSG-09 RabbitMQ retired (D-13). `make verify` exit 0. Review: assessed high, declined (user policy) | none | [x] 2026-11-09 |
| KAP-03 | broker | `security-event.schema.json` + valid/invalid examples tested in `broker/tests/`; decision record | KAP-02b | [ ] |
| KAP-04 | user-service | Migration `users.role` (`user`/`admin`), `ADMIN_BOOTSTRAP_EMAILS` idempotent bootstrap, role in profile response | none | [ ] |
| KAP-05 | gateway | Read role at login, `role` JWT claim, `require_admin` extractor (403), tests | KAP-04 | [ ] |
| KAP-06 | gateway | `SecurityEventPublisher` port + Kinesis adapter; emit scan.requested/cancelled, auth, ratelimit, deadlettered | KAP-02, KAP-03 | [ ] |
| KAP-07 | nmap-service | Port + Kinesis adapter; emit scan.started/completed/failed and finding.critical | KAP-02, KAP-03 | [ ] |
| KAP-08 | user-service | Port + Kinesis adapter; emit audit.recorded | KAP-02, KAP-03 | [ ] |
| KAP-09 | gateway | `src/kinesis.rs` consumer + `src/admin.rs` aggregator; `GET /api/admin/metrics` and SSE `GET /api/admin/events`; OpenAPI; LocalStack round-trip test | KAP-05, KAP-06 | [ ] |
| KAP-10 | front | `features/admin/`: container (EventSource + reducer), KPI tiles, scans in flight, critical findings feed, event log; `/admin` route guarded by role; Playwright `e2e/admin-panel.spec.ts` | KAP-09 | [ ] |
| KAP-11 | infra | End-to-end local check with compose; deploy and verify in Learner Lab; cut `v3` from `develop` | all | [ ] |

KAP-02..KAP-08 do not need a lab session and can start now. Only KAP-01 and KAP-11 need AWS.

## Branches

Each task is developed on its own branch, cut from `origin/develop` in its repo, and merges back to `develop` through its own PR. This plan document lives on `feature/kinesis_admin_plan` only.

| Task | Repo | Branch |
|---|---|---|
| KAP-00b | infra | `feature/kinesis_labrole_spike` |
| KAP-01 | infra | `feature/kinesis_stream` |
| KAP-02 | infra | `feature/localstack_kinesis` |
| KAP-02b | broker | `feature/retire_rabbitmq` |
| KAP-03 | broker | `feature/security_event_contract` |
| KAP-04 | user-service | `feature/user_role` |
| KAP-05 | gateway | `feature/admin_role_guard` |
| KAP-06 | gateway | `feature/security_event_publisher` |
| KAP-07 | nmap-service | `feature/security_event_publisher` |
| KAP-08 | user-service | `feature/security_event_publisher` |
| KAP-09 | gateway | `feature/admin_realtime_feed` |
| KAP-10 | front | `feature/admin_panel` |
| KAP-11 | infra | `feature/kinesis_e2e_deploy` |

## Admin panel (KAP-09/KAP-10) content

- KPI tiles: scans in flight, completed and failed in the last 15 minutes, failure rate, active users, rate-limit hits.
- Live list of scans in flight with status.
- Critical findings feed (newest first, capped).
- Raw event log (last 100 events, filter by type).
- SSE sends a snapshot first, then deltas; reconnect resumes with a fresh snapshot.

## Acceptance criteria

- A non-admin gets 403 on `/api/admin/*` and never sees the admin nav link.
- With compose running, a scan started by a normal user appears on an admin's `/admin` within 2 seconds, and its completion updates the counters.
- Stopping LocalStack Kinesis does not break scan submission; producers log the failure.
- Every event published in tests validates against the schema.

## Out of scope (follow-ups)

- Abuse detection rules over the stream.
- Firehose to S3 archive and analytics.
- Admin user-management UI (grant and revoke admin).

## Progress

- 2026-11-02: `v2` cut in all six repos; merged branches deleted. Plan written. KAP-00 blocked until a lab session is available.
- 2026-11-09: KAP-00 passed from the lab CLI session. KAP-00b (LabRole from ECS) added; it gates KAP-01.
- 2026-11-09: KAP-02b added (user decision): close the broker MSG-03..MSG-09 leftover from v2 before KAP-03, so the new contract lands in a broker repo without RabbitMQ.

## Next step

KAP-02b and KAP-03 done (KAP-03 on broker `feature/security_event_contract`). Next: KAP-03 (event contract) and KAP-02 (LocalStack Kinesis), in parallel; neither needs AWS. Push and PR of `broker` `feature/retire_rabbitmq` are the user decision.
