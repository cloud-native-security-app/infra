# report-email-queue (RF-20)

- Engram topic: `odd/report-email-queue/tasks` (project: `infra`)
- Repos: broker, infra, user-service
- Branches: `feature/report_email_queue` in each repo, from `develop`
- TDD: Strict TDD (user global config), runners `make verify` (broker, infra, user-service)
- Delivery: one PR per repo into `develop` (no stacked PRs); deploy order infra, then user-service
- Status: in progress (started 2026-11-26)

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
- **Reaper:** kept for the fallback path. In queue mode every receive refreshes the claim, so startup requires `REPORT_EMAIL_REAPER_AFTER_SECS` above the whole queue window (visibility timeout x `maxReceiveCount` + attempt deadline).
- **Shutdown:** a `CancellationToken` cancelled on SIGTERM or Ctrl-C stops the long poll. An in-flight email finishes first; unprocessed messages reappear after their visibility timeout.

## Tasks

| ID | Repo | Task | Route | Status |
|---|---|---|---|---|
| RFQ-01 | broker | `report-email-request.schema.json`, valid and invalid examples, `contracts.rs` constant, a test that validates them, README row, decision entry | delegated writer (2+ files) | [ ] |
| RFQ-02 | infra | Terraform queue and DLQ (redrive, redrive allow, TLS-only policies), user-service env (`AWS_REGION`, `REPORT_EMAIL_QUEUE_URL`, `REPORT_EMAIL_DLQ_URL`), outputs, tftests; LocalStack init and its test; compose env for user-service; README | delegated writer (2+ files) | [ ] |
| RFQ-03 | user-service | Store: queue claim with a lease (`claim_for_queue`). Service: `handle_request(scan_id, receive_count)` makes one attempt and returns `Done` or `Retry`, marking `failed` on the last receive. Unit tests with `FakeStore`, Postgres integration tests | delegated writer | [ ] |
| RFQ-04 | user-service | SQS adapter (publisher plus consumer loop, malformed to DLQ), config (`REPORT_EMAIL_QUEUE_URL`, `REPORT_EMAIL_DLQ_URL`, reaper window check), wiring with the in-process fallback, graceful shutdown, LocalStack tests, broker contract test, README, ADR-016 | delegated writer | [ ] |
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
