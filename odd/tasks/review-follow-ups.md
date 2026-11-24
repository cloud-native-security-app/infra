# Feature: review-follow-ups

Non-blocking findings from the native reviews of `odd/tasks/network-scan-email-siem.md` (EM-02, EM-05, SR-02, SR-05), turned into tasks. Every review was approved; none of these blocked delivery. Predecessor: `odd/tasks/network-scan-email-siem.md`.

## Objective

Close the review findings that change real behavior first (user-service email), then the ingestion edge cases (gateway), then test and script quality (infra), and finally confirm the facts that were never verified in the lab.

## Problem

- **Email (user-service, EM-02):**
  - The report email is sent in a background task after the outcome is stored.
  - A shutdown or crash in the middle loses the send and leaves `report_email_status = pending` forever, because nothing picks it up again.
  - `SMTP_TLS=none` still sends the username and password in clear text.
  - An unusable SMTP configuration silently disables email.
- **SIEM ingestion (gateway, SR-02):**
  - The rate limit (120 per 60 s) drops bursts, and Wazuh does not retry.
  - A publish retry can put the same alert on the stream twice, and there is no key to deduplicate it.
- **SMTP provisioning (infra, EM-05):**
  - `scripts/set-smtp.sh` writes four SSM parameters with no rollback when one fails.
  - The port placeholder is blank.
  - Some script tests assert less than their names claim.
- **SIEM flag (infra, SR-05):** the test does not assert the `siem_ingest_token_parameter` output that the README relies on.

## Scope

In scope: the findings listed in the tasks below.

Out of scope:
- The gaps that were scope decisions rather than review findings: the per-user email rate limit, and Kinesis audit for `report.emailed`.
- The pre-existing 64 KiB SSE frame risk in `scans_in_flight` and `recent_events`.
- Deploying Wazuh or Suricata.

Already done: the SR-02 OpenAPI finding (404 documented when the route is off). It was fixed in SR-06, gateway `7429cb8`.

## Constraints

- Strict TDD: enabled (session config).
  - Rust: `cargo test`, plus `make verify`.
  - Terraform: `terraform test`, plus `make verify`.
  - Scripts: `scripts/test-*.sh`.
- One branch per task from `develop` in its repo; work-unit commits with Conventional Commit messages.
- Push, PR and merge are user decisions.
- RDD: run a per-task `gentle-ai review assess --base-ref <branch point> --committed-only`. Relay consent for medium and high risk. Auto-decline whole-branch candidates with a stale base, per the user policy.
- Delivery strategy: `ask-on-risk`. The forecast is about 600 authored changed lines, spread over 4 repos, so every PR stays small.

## Decisions

- **RF-01 covers both the lost send and the stuck `pending`.** A reaper re-claims `pending` rows older than a threshold and retries them. That recovers a send lost on shutdown as well as one lost in a crash, so no graceful-shutdown drain is needed.
- **RF-02 refuses credentials without TLS.** Rejecting the config at startup is consistent with RF-03, which makes a bad config visible. Mailpit (local) uses `none` with no credentials and is unaffected. Open: whether to reject at startup or only log a warning; confirm with the user before RF-02 starts.
- **RF-05 deduplicates by `event_id`.** The gateway generates `event_id` once, before the retry loop, so a retried publish carries the same id; events-service ignores an `event_id` it has already seen in a bounded window. Check the first half before writing the second: the gateway may already do it.
- **RF-06 needs a product decision before it starts.** Options:
  - Raise the limit.
  - Make it configurable through `SIEM_INGEST_RATE_LIMIT`.
  - Keep the limit and document that Wazuh should filter by `level`.

## Tasks

| ID | Repo | Task | Depends on | Status |
| --- | --- | --- | --- | --- |
| RF-01 | user-service | Reaper for stuck report emails: periodically re-claim `pending` rows older than a threshold (e.g. 10 min, configurable) and retry the send. Keep it once per scan (atomic claim). Tests: a row left `pending` gets sent; a fresh `pending` row is left alone; two reapers do not both send | none | [x] 2026-11-23, user-service `acc6e1b` `f28fabe` |
| RF-02 | user-service | `SMTP_TLS=none` with `SMTP_USERNAME` or `SMTP_PASSWORD` set is rejected (or warned, see Decisions). Tests for both cases plus Mailpit without credentials | none | [x] 2026-11-23, user-service `b458d80` |
| RF-03 | user-service | An unusable SMTP config (bad port, bad TLS value, missing `SMTP_FROM` with a host) logs an error at startup naming the variable, instead of silently disabling email. Tests | none | [x] 2026-11-23, user-service `3921796` |
| RF-04 | gateway | SIEM publish retry keeps one `event_id` (verify, fix if not) | none | [x] 2026-11-24, gateway `c7f1bb1` |
| RF-05 | events-service | Ignore a repeated `event_id` within a bounded window (KPIs and feed count it once). Tests | RF-04 | [ ] |
| RF-06 | gateway | SIEM ingestion burst handling, per the user decision (see Decisions) | user decision | [ ] |
| RF-07 | gateway | Cleanup: move the misplaced `SIEM_INGEST_TOKEN` config doc comment; rename the limiter type that is named for scans | none | [ ] |
| RF-08 | infra | `scripts/set-smtp.sh`: on a failed SSM write, restore the previous values (or the placeholder) of the parameters already written; non-blank port placeholder; tests | none | [ ] |
| RF-09 | infra | Tighten `scripts/test-set-smtp.sh` (`--disable` and missing-password cases assert what they claim); fix the LabRole tftest message wording | none | [ ] |
| RF-10 | infra | `siem.tftest.hcl` asserts `siem_ingest_token_parameter`: null when disabled, the parameter name when enabled | none | [ ] |
| RF-11 | lab | Verify in the lab: SSM accepts the single-space placeholder; the report email arrives through Gmail; SIEM end to end (flag on, sample POST with the token appears in "Alertas IDS", wrong token gets 401) | infra #52 merged, Gmail App Password | [ ] |
| RF-12 | docs | Check the severity bands (0-6, 7-9, 10-12, 13-15) and the README Wazuh syntax (`<integration>`, `integratord` arguments, Suricata `<localfile>`, `data.alert.signature`) against the Wazuh docs; correct D-18 or the README if they differ | none | [ ] |
| RF-13 | user-service | Bound one SMTP attempt with an overall deadline (connect through DATA) and validate that `after` exceeds the deadline plus the largest retry backoff, so a live sender is never judged stale. From the `f28fabe` review (2 warnings) | RF-01 | [ ] |
| RF-14 | user-service | Write `failed` and the `report.email_failed` audit in one transaction in `fail_unrecoverable`; fix its log message for a missing owner; test that a transient error (e.g. `find_user`) leaves the row `pending` with no audit. From the `f28fabe` review | RF-01 | [ ] |
| RF-15 | user-service, nmap-service | Contract drift: `SecurityEvent` does not know `siem.alert`, so `security_event_contract` fails locally against broker develop (CI skips it because it does not check out `../broker`). Add the variant or ignore unknown types explicitly; consider checking out broker in CI | none | [ ] |

## Branches

| Task | Repo | Branch |
| --- | --- | --- |
| RF-01 | user-service | `fix/report_email_reaper` |
| RF-02, RF-03 | user-service | `fix/smtp_config_checks` |
| RF-04 | gateway | `fix/siem_event_id_retry` |
| RF-05 | events-service | `fix/siem_event_dedup` |
| RF-06, RF-07 | gateway | `fix/siem_ingest_limits` |
| RF-08, RF-09 | infra | `fix/set_smtp_rollback` |
| RF-10 | infra | `test/siem_output` |

## Order

1. RF-01, then RF-02 and RF-03. They change real behavior; RF-02 waits for the decision.
2. RF-04, then RF-05.
3. RF-06 (after the decision) and RF-07.
4. RF-08, RF-09 and RF-10.
5. RF-11 and RF-12 whenever the lab and the Gmail account are ready.

## Acceptance

- A report email interrupted by a restart is sent after the restart, exactly once.
- user-service refuses to send credentials over an unencrypted connection, and a bad SMTP config is visible in the logs.
- A retried SIEM alert is counted once in the admin panel.
- All repo checks (`make verify`) stay green.

## Progress

Created 2026-11-23 from the review findings recorded in `odd/tasks/network-scan-email-siem.md`.

RF-01 done 2026-11-23 (user-service `acc6e1b` + `f28fabe`, branch `fix/report_email_reaper`; route: delegated writer, two commits; Strict TDD RED = missing `ReaperPolicy`/`reap_once`/`reclaim_stale`, then the slow-send, queued-batch, zero-interval, minimum-threshold, `touch` and unreadable-row tests; `cargo test --test report_email -- --include-ignored` 14 passed (parent spot check); `make verify` stops at the known `security_event_contract` failure (RF-15), the remaining steps pass when run by hand). New column `report_email_claimed_at` (falls back to `updated_at` for older rows); `FOR UPDATE SKIP LOCKED` batches of 20; `REPORT_EMAIL_REAPER_AFTER_SECS` (default 600, minimum 120) and `REPORT_EMAIL_REAPER_INTERVAL_SECS` (default 60, zero clamped to 1 s); the reaper runs only with a mailer; a heartbeat refreshes the claim of the current and queued rows before every attempt; unreadable stored data or a missing owner marks the row `failed` and audits it; transient DB errors stay `pending`. Delivery is at-least-once (README). RDD medium, granted twice: `acc6e1b` approved (review-12a369d14f21246c) with 2 warnings and 1 suggestion, fixed in `f28fabe`; `f28fabe` approved (review-4c190f581b30a8e8) with 2 warnings and 2 suggestions, now RF-13 and RF-14. RF-02 and RF-03 done 2026-11-23 (user-service `b458d80` + `3921796`, branch `fix/smtp_config_checks`; route: delegated writer; Strict TDD RED = missing `InsecureSmtpCredentials`, then a single credential with `none` hit the pair check first, then `SMTP_HOST="bad host"` was accepted; most other RF-03 cases already failed closed and are now regression tests; `cargo test --lib config` 38 passed (parent spot check); `make verify` stops at the known RF-15 failure, the remaining steps pass by hand; RDD medium, under budget, no review due). User decision 2026-11-23: `SMTP_TLS=none` with `SMTP_USERNAME` or `SMTP_PASSWORD` fails startup (message names the variables, never the values). With a non-blank `SMTP_HOST`, a bad port, an unknown `SMTP_TLS`, an invalid or missing `SMTP_FROM` (with no username to default to), a single credential, or a host with characters outside `A-Za-z0-9 . - _ : [ ]` fails startup naming the variable. A blank or whitespace host still disables email, so the lab single-space SSM placeholders start fine (dedicated test); compose (Mailpit, `none`, no credentials) is unaffected. Gaps: the mailer-build fallback in `wiring.rs` is now unreachable and kept as a logged defensive branch; the host check is an allowlist, not full hostname validation. RF-04 done 2026-11-24 (gateway `c7f1bb1`, branch `fix/siem_event_id_retry`; route: direct inline, one test file). Verified: `siem_ingest` builds the `SecurityEvent` (and its `event_id`, a UUID v4) once and passes it by reference to `publish_with_retry`, so every attempt carries the same id; no fix needed. Added the regression test `a_retried_siem_alert_keeps_one_event_id_across_attempts` (hang, fail, ok: three attempts, one id). Characterization test, so no RED was observable (the behavior already existed). `make verify` exit 0. RDD high (security file), granted by the user, four lenses approved and acknowledged with 3 suggestions: `seen` duplicates the `attempts` counter in the test double; the doc comment implies deduplication is tested when only id stability is. A landed hung attempt plus its retry (two deliveries, same id) is what RF-05 must deduplicate. Next: RF-05.
