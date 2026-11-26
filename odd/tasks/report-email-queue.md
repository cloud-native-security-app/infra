# report-email-queue (RF-20)

- Engram topic: `odd/report-email-queue/tasks` (project: `infra`)
- Repos: broker, infra, user-service
- Branches: `feature/report_email_queue` in each repo, from `develop`
- TDD: Strict TDD (user global config), runners `make verify` (broker, infra, user-service)
- Delivery: one PR per repo into `develop` (no stacked PRs); deploy order infra, then user-service
- Status: code done 2026-11-26; lab check (RFQ-05) pending

## Objective

Send the scan report email through an SQS queue with a DLQ, so the email is decoupled from the scan status update and SQS drives the retries. User decision 2026-11-26: use SQS (RF-20), with the consumer inside user-service.

## Problem

Today `PATCH /scans/{id}` with `COMPLETADO` starts an in-process task (`spawn_for_completed`) that claims the row in Postgres (`scan_history.report_email_status`), tries SMTP 3 times (2 s and 4 s backoff, 60 s per attempt) and marks it `sent` or `failed`. A reaper resends rows stuck in `pending`. It works, but retries live in process memory and the design differs from the rest of the system, which moves work between services over SNS and SQS with DLQs.

## Design

- **Queue:** `user-service-report-emails`, with DLQ `user-service-report-emails-dlq`. SSE on. `maxReceiveCount = 3`, long poll 20 s, visibility timeout 120 s. user-service sends to it directly, with no SNS topic. These are separate Terraform resources, outside `local.scan_queues`, because every entry there needs a topic.
- **Message:** `ReportEmailRequest` `{ "scan_id": string, "requested_at": date-time }`, in `broker/contracts/report-email-request.schema.json`, with `additionalProperties: false`.
- **Producer:** after `update_scan_outcome` succeeds with `COMPLETADO`, user-service sends the message. If the send fails, it logs a warning and falls back to the current in-process path (`spawn_for_completed`), so the email is not lost.
- **Consumer:** a loop inside user-service, modelled on `gateway/src/sqs.rs`. It long-polls, and for each message:
  1. **Claim** the row atomically. A row in no state yet, in `pending` or in `failed` can be claimed when it has no live lease (`report_email_claimed_at` older than the visibility timeout). `sent` and `disabled` are final.
  2. **One SMTP attempt** with the 60 s deadline.
  3. **Success:** `sent`, audit, then delete the message.
  4. **Transient failure:** leave `pending` and keep the message. SQS redelivers it after the visibility timeout, about 2 minutes later.
  5. **Failure on the last receive** (`ApproximateReceiveCount >= 3`): `failed` and an audit entry. The message is not deleted, so the redrive moves it to the DLQ, where it can be inspected and redriven. A redriven message can claim a `failed` row again.
  6. **Malformed body:** forwarded to the DLQ and deleted, never logged.
  7. **Already final or leased** (duplicate delivery): delete without sending.
- **Without SMTP:** the row is marked `disabled` and the message deleted, as today.
- **Local and tests:** when `REPORT_EMAIL_QUEUE_URL` is unset, the current in-process path is unchanged. Compose and the lab set it.
- **Queue attributes:** at startup user-service reads `VisibilityTimeout` and the redrive `maxReceiveCount` from the queue (`GetQueueAttributes`). The claim lease, the last-receive threshold and the reaper window derive from them, so Terraform stays the only place to change them (review finding R2-coupled-queue-window).
- **Reaper:** kept for the fallback path. In queue mode every receive refreshes the claim, so startup requires `REPORT_EMAIL_REAPER_AFTER_SECS` above the whole queue window (visibility timeout x `maxReceiveCount` + attempt deadline).
- **Shutdown:** a `CancellationToken` cancelled on SIGTERM or Ctrl-C stops the long poll. An in-flight email finishes first; unprocessed messages reappear after their visibility timeout.

## Tasks

| ID | Repo | Task | Route | Status |
|---|---|---|---|---|
| RFQ-01 | broker | `report-email-request.schema.json`, valid and invalid examples, `contracts.rs` constant, a test that validates them, README row, decision entry | delegated writer (2+ files) | [x] broker `78985f0` |
| RFQ-02 | infra | Terraform queue and DLQ (redrive, redrive allow, TLS-only policies), user-service env (`AWS_REGION`, `REPORT_EMAIL_QUEUE_URL`, `REPORT_EMAIL_DLQ_URL`), outputs, tftests; LocalStack init and its test; compose env for user-service; README | delegated writer (2+ files) | [x] infra `05adfc3` + follow-up |
| RFQ-03 | user-service | Store: queue claim with a lease (`claim_for_queue`). Service: `handle_request(scan_id, receive_count)` makes one attempt and returns `Done` or `Retry`, marking `failed` on the last receive. Unit tests with `FakeStore`, Postgres integration tests | delegated writer | [x] user-service `e28b352` |
| RFQ-04 | user-service | SQS adapter (publisher plus consumer loop, malformed to DLQ), config (`REPORT_EMAIL_QUEUE_URL`, `REPORT_EMAIL_DLQ_URL`, reaper window check), wiring with the in-process fallback, graceful shutdown, LocalStack tests, broker contract test, README, ADR-016 | delegated writer | [x] user-service `f5c011a` + `19a01be` |
| RFQ-05 | lab | Apply infra, deploy user-service, then: email arrives through the queue; a forced SMTP failure retries and ends in the DLQ with `failed` | parent, user-authorized | [ ] |

## Acceptance criteria

- A completed scan publishes one message, and its owner receives one email.
- A redelivered or duplicated message never sends a second email.
- A transient SMTP failure is retried by SQS. After 3 receives the row is `failed` (and audited) and the message is in the DLQ.
- A malformed message goes to the DLQ without its body being logged.
- If the queue send fails, the email still goes out through the in-process path.
- With no queue URL, behavior is unchanged.

## Checks

- broker: `make verify`
- infra: `make verify` (terraform tests, LocalStack init test)
- user-service: `make verify` (includes the Docker integration tests)

## Delivery forecast

About 900 authored lines: broker ~120, infra ~200, user-service ~600. One PR per repo. user-service goes in two commits (RFQ-03, RFQ-04) and its PR exceeds 400 lines; it is reviewed as two work units.

## Progress

- 2026-11-26: exploration done (delegated mapper); design recorded above.
- 2026-11-26 RFQ-01 (broker `78985f0`, delegated writer): `report-email-request.schema.json` (with the RFC 3339 `pattern` on `requested_at`, since `format` is only an annotation in draft 2020-12), valid and invalid examples, `REPORT_EMAIL_REQUEST_SCHEMA` and `validate_report_email_request`, README, D-19. The broker pre-commit hook (AGENTS.md: `topology.rs` is the only source of truth for queues) blocked the first commit, so the queue was added to `topology.rs` with `QueueSpec.topic: Option` (`None` = no SNS), and `topology_parity.rs` checks its own Terraform block and the LocalStack lines. Strict TDD RED: `E0425 validate_report_email_request`; then both parity tests failed on the new spec before the parser learned the separate-block shape. `make verify` rc 0 (62 unit, 2 parity, LocalStack 7). RDD: declined (user policy).
- 2026-11-26 RFQ-02 (infra `05adfc3`, delegated writer): queue and DLQ as separate resources, user-service env (`AWS_REGION`, `REPORT_EMAIL_QUEUE_URL`, `REPORT_EMAIL_DLQ_URL`), outputs `report_email_queue_url`/`report_email_dlq_url`, tftests, LocalStack init and its test, compose, README. RED: `environment_matches_the_legacy_json` failed (undeclared resource); the LocalStack test was edited together with the script (no separate RED). `make verify` rc 0 (76 Terraform tests, `test-localstack-init: OK`). RDD high, granted by the user, four lenses approved and acknowledged (review-6ad047762f7f6c62) with 1 warning and 6 suggestions. Warning R2-coupled-queue-window (visibility and maxReceiveCount are coupled to user-service logic): user-service will read both from the queue at startup (RFQ-04), and messaging.tf says so (follow-up commit). Suggestions left: no DLQ depth alarm (R4); bare `120` in localstack-init; a stale visibility comment and a substring check in test-localstack-init; the compose wait condition is not asserted.
- 2026-11-26 RFQ-03 (user-service `e28b352`, delegated writer, +578/-21): `claim_for_queue(scan_id, lease)` (one atomic UPDATE; claims NULL, or pending/failed with an expired lease; never sent/disabled or a non-completed scan) and `handle_request(scan_id, receive_count, max_receives, lease) -> QueueOutcome`. Decisions beyond the spec: an unrenderable report is marked failed + audited and returns Done (a retry cannot help, same as the in-process path); unreadable stored data is failed atomically inside the claim (`claimed_outcome`) and returns Done; if `finish(Sent)` fails after a successful send it returns Done (at-least-once: the reaper may resend after the lease). RED: compile errors (E0432 `QueueOutcome`, E0407 `claim_for_queue`, E0599 `handle_request`). `make verify` rc 0 (160 unit incl. 12 new; Docker suites all pass incl. 9 new Postgres/Mailpit tests). RDD medium, slice_budget_reached, declined (user policy).
- 2026-11-26 RFQ-04 (user-service `f5c011a`, delegated writer, 17 files +1819/-24): `aws-sdk-sqs` 1.114.0 and `tokio-util` 0.7 (gateway pins); `src/report_email/queue.rs` (`ReportEmailRequest`, publisher port, `RecordingPublisher`, parsers, `QueueSettings`, `request_report_email` = publish with a 5 s timeout, else `spawn_for_completed`); `src/messaging/sqs.rs` (publisher, consumer loop, malformed to DLQ); config `REPORT_EMAIL_QUEUE_URL`/`REPORT_EMAIL_DLQ_URL` (both or neither); `wiring::build_app` + graceful shutdown (SIGTERM/Ctrl-C, consumer awaited); README, ADR-016; LocalStack tests (send and delete, malformed to DLQ, failing SMTP to `failed` + DLQ, duplicate sends once, cancellation); broker contract test. Writer decisions: claim lease = 90% of VisibilityTimeout (with 100% a redelivery finds the lease alive and is deleted as a duplicate); `MAX_MESSAGES = 1` (a 60 s attempt would let the rest of a batch outlive the visibility timeout); missing receive count = 1. RED: compile errors (20 for the queue module, 3 for config, 1 for `lease`); `request_report_email`, LocalStack and contract tests were written with the code (no separate RED). `make verify` rc 0. RDD high, granted by the user, four lenses approved and acknowledged with 3 warnings and 6 suggestions. Warnings (visibility not checked against the 60 s attempt; field doc said visibility is the lease) fixed in `19a01be`: `check_lease_covers_attempt` at startup (fails naming the queue), one `RetryPolicy` source for service, fallback and both checks, doc fixed, dead `PublishError::TimedOut` removed, an assertion-less test deleted. RED: E0425 `check_lease_covers_attempt`. `make verify` rc 0 (185 lib, 3 contract, Docker suites pass). RDD medium under budget. Suggestions left: `RecordingPublisher` is public (used by integration tests); a dead consumer task is not detected while HTTP keeps serving (follow-up); `build_app` in queue mode has no direct test.
