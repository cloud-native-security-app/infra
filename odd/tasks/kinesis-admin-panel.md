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
- Stream name env var for all producers/consumer: `SECURITY_EVENTS_STREAM_NAME` (value `security-events`), already set in compose for gateway, nmap-service and user-service (KAP-02). user-service also got `AWS_REGION`, `AWS_ENDPOINT_URL` and dummy `test`/`test` credentials; it has no `depends_on: localstack` yet (add in KAP-08 if it needs the stream at boot).
- Stream: PROVISIONED, 1 shard, 24h retention (AWS default; the lab SCP denies changing it, so in the lab the stream is created by CLI and imported, see `terraform/README.md`). Partition key: `scan_id`, else `actor_sub`.
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

- Learner Lab: every resource uses `LabRole`. Kinesis Data Streams works from the lab CLI session (KAP-00, 2026-11-09); and as `LabRole` from an ECS Fargate task (KAP-00b, 2026-11-10). The SNS fan-out fallback is no longer needed.
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
| KAP-00b | infra | Spike: same put/get as `LabRole` from a Fargate task (MSG-02 pattern: `public.ecr.aws/aws-cli/aws-cli`, task and execution role `LabRole`); record result or fallback. **Result 2026-11-10: YES.** A Fargate task (image `public.ecr.aws/aws-cli/aws-cli:latest`, task and execution role `LabRole`, default VPC with public IP, temporary cluster) ran as `assumed-role/LabRole`, `put-record` returned a sequence number, `get-records` (TRIM_HORIZON) read the record back, exit code 0. All `kap00b-spike` resources (stream, task definition, cluster, log group) deleted afterwards. Gotcha (same as MSG-02): the first `run-task` failed with "Unable to assume the service linked role"; a retry 20 s later succeeded. | KAP-00 | [x] 2026-11-10 |
| KAP-01 | infra | `terraform/streaming.tf` stream + SSM name + ECS env wiring; `.tftest.hcl` (RED first). **Done 2026-11-10** on `feature/kinesis_stream` (38f3eec stream+outputs+tests, 2899c6d env wiring, docs commit docs; not pushed; no apply). Name goes as plain env var `SECURITY_EVENTS_STREAM_NAME` (same pattern as SQS/SNS), not SSM, because it is not a secret. No IAM resources (LabRole, KAP-00b). RED: new `streaming.tftest.hcl` + env run failed (resource not declared; 52 passed, 2 failed, 4 skipped). GREEN: `terraform test` 58 passed, 0 failed. `make verify` exit 0. Review: no assessment run by the writer | KAP-00b | [x] 2026-11-10 |
| KAP-02 | infra | LocalStack: enable `kinesis`, create `security-events` in the init script, extend its offline test; START.md section B. **Done 2026-11-09** on `feature/localstack_kinesis` (1106430 compose+init+test, START.md+plan commit follows; not pushed). RED: extended `scripts/test-localstack-init.sh` first, 12 FAIL lines (no create-stream, no kinesis in SERVICES, no env var). GREEN: `test-localstack-init: OK`. `make verify` exit 0, `docker compose config -q` OK. Live LocalStack 4.4: healthy, `describe-stream-summary` ACTIVE, PROVISIONED, 1 open shard, 24h; put-record/get-records round-trip OK. Review: no assessment run by the writer (policy: decline) | none | [x] 2026-11-09 |
| KAP-02b | broker | Close the v2 leftover `odd/tasks/sqs-sns-migration.md` MSG-03..MSG-09 before adding the new contract: first reconcile each item against what infra already delivered (LocalStack compose, TF-10 topology) and tick what is covered with evidence; then finish the rest (contract, DLQ, and encryption tests on LocalStack; parameter hand-off; retire `rabbitmq/`, AMQP test code, and `lapin`/testcontainers-rabbitmq). Mark `amazon-mq-migration.md` as superseded. **Done 2026-11-09** on `feature/retire_rabbitmq` (0509ac1, 8c09e62, ee1aaa4, 1ff2fab; not pushed): MSG-03 ticked by reconciliation (infra LocalStack), MSG-04..07 LocalStack tests, MSG-08 offline parity test vs `../infra`, MSG-09 RabbitMQ retired (D-13). `make verify` exit 0. Review: assessed high, declined (user policy) | none | [x] 2026-11-09 |
| KAP-03 | broker | `security-event.schema.json` + valid/invalid examples tested in `broker/tests/`; decision record | KAP-02b | [x] merged to `develop` |
| KAP-04 | user-service | Migration `users.role` (`user`/`admin`), `ADMIN_BOOTSTRAP_EMAILS` idempotent bootstrap, role in profile response | none | [x] merged to `develop` |
| KAP-05 | gateway | Read role at login, `role` JWT claim, `require_admin` extractor (403), tests | KAP-04 | [x] merged to `develop` |
| KAP-06 | gateway | `SecurityEventPublisher` port + Kinesis adapter; emit scan.requested/cancelled, auth, ratelimit, deadlettered | KAP-02, KAP-03 | [x] merged to `develop` |
| KAP-07 | nmap-service | Port + Kinesis adapter; emit scan.started/completed/failed and finding.critical | KAP-02, KAP-03 | [x] merged to `develop` |
| KAP-08 | user-service | Port + Kinesis adapter; emit audit.recorded | KAP-02, KAP-03 | [x] merged to `develop` |
| KAP-09 | gateway | `src/kinesis.rs` consumer + `src/admin.rs` aggregator; `GET /api/admin/metrics` and SSE `GET /api/admin/events`; OpenAPI; LocalStack round-trip test | KAP-05, KAP-06 | [x] merged to `develop` |
| KAP-10 | front | `features/admin/`: container (EventSource + reducer), KPI tiles, scans in flight, critical findings feed, event log; `/admin` route guarded by role; Playwright `e2e/admin-panel.spec.ts` | KAP-09 | [x] merged to `develop` |
| KAP-07b | broker, nmap-service, gateway | Optional `port`/`protocol` on `vulnFinding` and nullable port in `finding.critical` (host-level findings) | KAP-07 | [x] merged to `develop` |
| KAP-11 | infra | End-to-end local check with compose; deploy and verify in Learner Lab; cut `v3` from `develop` | all | [~] lab deploy verified 2026-11-11; local compose check replaced by the lab check; `v3` cut pending |

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
| KAP-11 | infra | `fix/kinesis_retention_scp`, `fix/admin_bootstrap_emails` (fixes found by the deploy) |

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
- 2026-11-09: KAP-02 done: LocalStack `kinesis`, stream `security-events` created by the init hook, env var wired in compose.
- 2026-11-09: KAP-02b added (user decision): close the broker MSG-03..MSG-09 leftover from v2 before KAP-03, so the new contract lands in a broker repo without RabbitMQ.
- 2026-11-10: KAP-03, KAP-04 (with flaky-test fix) and KAP-05 merged to `develop`. KAP-05 review findings: R1-001 (no role revocation) and R4 (unknown role claim rejects the whole session) must be resolved in KAP-09 before admin routes are mounted.
- 2026-11-10: KAP-00b passed: `LabRole` reads and writes Kinesis from a Fargate task. KAP-01 is unblocked.
- 2026-11-10: KAP-01 done offline (not applied). KMS gap closed the same day: the KAP-00b procedure repeated on a stream encrypted with `start-stream-encryption --encryption-type KMS --key-id alias/aws/kinesis` (status ACTIVE, EncryptionType KMS); the Fargate task as `assumed-role/LabRole` put and read back a record, exit code 0. All `kap01-kms-spike` resources deleted.
- 2026-11-10/11: KAP-06..KAP-10 and KAP-07b merged to `develop` in gateway, nmap-service, user-service, broker and front.
- 2026-11-11: KAP-11 deploy into a fresh Learner Lab (the previous one ran out of credits): state bucket and namespace bootstrapped, `terraform apply`, `push-images.sh`, `set-google-oauth.sh`; `verify-stack.sh` 10 passed, 0 failed. All three producers log publishing to `security-events`. The user logged in as admin and checked `/admin` live. Two fixes found by the deploy, both merged to `develop`:
  - `fix/kinesis_retention_scp` (infra #27): the lab SCP denies `kinesis:IncreaseStreamRetentionPeriod`, and aws provider 6.x calls it on every stream create (schema default 24). The stream is now created with the AWS CLI and imported; updates (KMS) work after import. The KAP-00b and KMS spikes missed it because they created the stream by CLI.
  - `fix/admin_bootstrap_emails` (infra #28): Terraform did not pass `ADMIN_BOOTSTRAP_EMAILS` to user-service, so AWS had no admin. New list variable `admin_bootstrap_emails`, passed at apply time (`TF_VAR_admin_bootstrap_emails`); every later apply must pass it or the empty default revokes all admins.

## Next step

KAP-00 to KAP-10 done and deployed to the lab. Last step: cut `v3` from `develop` in all six repos, then release `develop` to `main` by PR. Follow-ups: event retry/outbox, panel gap after a gateway restart (consumer starts at LATEST), admin nav link stays until reload after a role loss.
