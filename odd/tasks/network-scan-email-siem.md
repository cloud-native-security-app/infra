# Feature: network-scan-email-siem

Master plan for the work after the admin panel improvements. Each task lives in its own repo and branch. Predecessor: `odd/tasks/admin-panel-improvements.md`.

## Objective

1. Let a user scan a target with only its IP, without SSH credentials.
2. Email the scan report to the user.
3. Leave the application ready to receive alerts from Wazuh and Suricata, without deploying either of them. They will be added later in another lab or cloud.

## Problem

1. A scan always needs SSH credentials. nmap-service does not scan from its own container: it opens an SSH session to the target and runs `nmap -sV --script vuln` there, then runs the patch check (`dnf|yum updateinfo`) over the same session (`nmap-service/src/pipeline.rs:528-590`, `scanner.rs:218-241`, `patch_verify.rs`). The gateway rejects a target without a stored credential with 422 (`gateway/src/api.rs:827-831`). The scan-request contract requires `network_user` and `ssh_credentials_ref` (`broker/contracts/scan-request.schema.json`), and so does `ScanRequest` (`nmap-service/src/domain.rs:142-152`).
2. The report is only a JSON file built in the browser (`front/src/features/report/buildReportExport.ts`). There is no email code anywhere. In the Learner Lab, SES is denied (`ses:GetAccount` and `ses:ListIdentities` return AccessDenied, checked 2026-11-12).
3. There is no IDS or SIEM. Because nmap runs inside the target over SSH, a network IDS on the target would see no scan traffic today; the network mode in part 1 changes that.

## Decisions

- **Two scan modes.** `ssh` (today's behavior, unchanged) and `network`: nmap-service runs nmap in its own container against the target IP.
- **nmap runs inside the nmap-service image (user decision 2026-11-12).** The runtime base changes from distroless to a slim Debian with the `nmap` package, running as a non-root user. This reverses the documented decision "SSH al objetivo, no escaneo local" (`nmap-service/docs/architecture.md`, `Dockerfile`), so NS-02 updates both. Rejected: a separate always-on scanner service (one more Fargate task) and a Fargate task per scan (30-60 s start, results through S3).
- **Network mode is unprivileged.** It uses `nmap -sT -sV --script vuln` (TCP connect, no raw sockets, no `-O`), so it runs on Fargate without extra capabilities. There is no patch check, so findings keep `confidence=version_match` and the report says the patch state was not verified.
- **Network mode is limited to an allowlist of accounts (user decision 2026-11-12, academic use).** Without credentials, the stored SSH credential no longer proves that the target is the user's, and scanning third-party hosts from AWS breaks its acceptable-use policy. The user chose to control *who* may scan: a few authorized emails, managed by the user. They come from the Terraform variable `network_scan_emails`, applied by user-service at startup like `admin_bootstrap_emails` (authoritative: removing an email revokes the permission). The gateway re-validates the permission against user-service on every network scan, like `require_admin`. The front only shows the mode to authorized accounts. Targets are open by default, with an optional `network_scan_allowed_cidrs` (empty = any). A fixed denylist always applies: loopback, link-local (including the instance metadata endpoint `169.254.169.254`), multicast, broadcast and unspecified addresses.
- **The scanner is isolated from the app services.** nmap-service moves out of `internal-sg` into its own security group whose only ingress rule elsewhere is Mongo (27017). A network scan from it cannot reach the gateway, user-service, events-service or Postgres. A separate VPC for targets was considered and is not needed for academic use.
- **Email through a generic SMTP provider, not SES or SNS.** SES is denied in the lab, and SNS email only sends plain text with no attachment and needs a subscription confirmation per address. user-service sends the email with an SMTP client (`lettre`). It already owns the user's email and the stored result. SMTP host, port, user and password come from SSM; with no host configured, email is disabled and the API answers 503. Port 587 with STARTTLS (AWS only throttles 25). The lab uses Gmail with a dedicated account (decision 3); local development and tests use Mailpit; production can use any SMTP provider.
- **The email is sent automatically when a scan completes (user decision 2026-11-12).** user-service already records the outcome (`update_scan_outcome`, `user-service/src/repository.rs:282`); when the stored outcome is `completed` it sends the report in the background. The send is best-effort with bounded retry, never fails the outcome update, and runs once per scan (a `report_emailed_at` column makes it idempotent across redeliveries). Failed scans send nothing.
- **An email always goes to the user's own address.** It goes to the account's email only, never to a free-form recipient, so the feature cannot be used to send spam. Body: an HTML summary (target, date, severity counts, top findings). Attachment: the same JSON the browser exports today. Sending is rate limited per user.
- **SIEM-ready means seams, not services.** No Wazuh, Suricata or EC2 for them in this plan. The app gets:
  - a `siem.alert` event type in the broker contract;
  - an authenticated ingestion endpoint that a Wazuh integration can POST alerts to;
  - an aggregator and panel view for those alerts;
  - feature flags so all of it is off by default;
  - a document describing how to connect a Wazuh manager and Suricata later.
- **Version-based CVEs come from NVD in both modes (user decision 2026-11-12).** NS-00 showed that `vulners` returns nothing without an API key. The existing NVD 2.0 enrichment by CPE (`nmap-service/src/enrichment/nvd.rs`, run in `pipeline.rs` after the parse) is turned on: `MS_NMAP_NVD_ENRICHMENT_ENABLED=true` and `MS_NMAP_NVD_CACHE_TTL_SECS` in Terraform (NS-05). The API key (`MS_NMAP_NVD_API_KEY`) stays optional; without it NVD allows about 5 requests per 30 s, and the Mongo cache absorbs repeats. NS-02 keeps the enrichment step in the network path.
- **The ingestion endpoint lives in the gateway**, which is already the only public entry point and a Kinesis producer. Route: `POST /api/integrations/siem/alerts`. Auth: a bearer token stored in SSM, compared in constant time. With no token configured the route returns 404, so it is off by default. It is rate limited. It maps a Wazuh alert (rule level, rule id, description, agent, source and destination IP, and Suricata `data.alert.signature` when present) into the `siem.alert` payload and publishes it with the existing retry policy (AP-07).

## Open decisions

1. ~~Allowlist source~~. Resolved 2026-11-12 (user): an allowlist of accounts (`network_scan_emails`), not of targets.
2. ~~Email trigger~~. Resolved 2026-11-12 (user): the email is sent automatically when the scan completes.
3. ~~SMTP provider~~. Resolved 2026-11-21 (user): Gmail (`smtp.gmail.com:587`, STARTTLS) with a dedicated account that has 2-Step Verification and an App Password; the App Password is the SMTP password in SSM (EM-05), never in Terraform or the repo. Real mail leaves the lab, so it only goes to the account email of authorized users (existing recipient rule). Gmail caps sending at about 500 messages a day, enough for academic use. Local development and tests use Mailpit. Rejected: Mailtrap sandbox (no real delivery), Brevo/Resend (extra account and domain setup), SES (denied in the lab).

## Constraints

- Strict TDD (user global config): RED before GREEN in every task.
- `ssh` mode keeps its current behavior and payloads; contract changes are additive.
- New API fields go to the OpenAPI, the front guards and the contract-server mock.
- Learner Lab: no SES. nmap-service runs as `LabRole` on Fargate. More memory costs credit.
- Artifacts in English, Conventional Commits, no attribution.
- One branch per task, cut from `develop`; PRs target `develop`.

## Tooling

- Runners: front `npm run verify` and Playwright; Rust services `make verify`; broker contract tests; infra `make verify`.
- Review: per stored user policy, decline reviews except tasks touching permissions or secrets: NS-07 (network scan permission), NS-03 (permission check and denylist), EM-02 (SMTP secret and recipient rule), SR-02 (ingestion token).

## Checklist

### Part 1: network scan (IP only)

| ID | Repo | Task | Depends on | Done |
|---|---|---|---|---|
| NS-00 | infra | Local spike: a slim Debian image with `nmap` as a non-root user runs `nmap -sT -sV --script vuln -oX -` against a local target container; record that it needs no extra capability, duration, memory peak and XML shape. The Fargate run is checked in NS-06 | none | [x] 2026-11-12, results in Progress |
| NS-01 | broker | `scan-request` contract: `scan_mode` (`ssh` default, `network`); `network_user` and `ssh_credentials_ref` required only when `ssh` (JSON Schema if/then); `scan.requested` event payload carries the mode; examples and tests | none | [x] 2026-11-12, broker `b6d478a` |
| NS-02 | nmap-service | Local executor that runs nmap in the container (`-sT -sV --script vuln -T<n> -oX -`, no `-O`, no sudo); pipeline picks the executor by mode; network mode skips the patch check and records why; NVD enrichment runs in both modes; nmap in the image; parser reused; timeouts and reason codes (`target_unreachable`); unit tests and a testcontainers test against a local target | NS-01 | [x] 2026-11-12, nmap-service `36195a2`, `65f3001` |
| NS-03 | gateway | `POST /api/scans` accepts `mode`; `network` requires the `network_scan` permission re-validated against user-service (403 otherwise), skips credential resolution, rejects denylisted targets and, if `NETWORK_SCAN_ALLOWED_CIDRS` is set, targets outside it (422 with a reason); `ssh` unchanged; publishes the new contract; OpenAPI; tests | NS-01, NS-07 | [x] 2026-11-12, gateway `b96a6dc`, `40d61fd` (+ review follow-up) |
| NS-04 | front | Scan form: mode choice (SSH credentials or IP only) shown only when `/api/me` says the account has the `network_scan` permission; IP-only explains that patch state is not verified; mode shown in history and report; 403 and 422 messages; guards and contract-server mock; vitest and Playwright | NS-03 | [x] 2026-11-12, front `e91e9fc`, `937af7f`, `380c6f0` |
| NS-05 | infra | `network_scan_emails` variable (email list, validated like `admin_bootstrap_emails`) to user-service env; optional `network_scan_allowed_cidrs` (default empty) to the gateway env; nmap-service in its own security group (egress all, ingress allowed only into Mongo); NVD enrichment on for nmap-service (`MS_NMAP_NVD_ENRICHMENT_ENABLED=true`, `MS_NMAP_NVD_CACHE_TTL_SECS=86400`); `create-test-target.sh` and `create-weak-target.sh` open the target SG to the nmap-service SG; compose; tests and README | NS-00 | [x] 2026-11-12, infra `e86be94`, `5ab0ce1` (+ review follow-up) |
| NS-06 | infra | Lab deploy and check: network scan of the weak target from the UI with an authorized account; a non-authorized account does not see the mode and gets 403 from the API; ssh scan still works; nmap-service cannot reach the gateway or Postgres | NS-02..NS-05, NS-07 | [x] 2026-11-18, UI checks passed (see network-scan-url-target.md UT-05) |
| NS-07 | user-service | `network_scan` permission: migration (`users.can_network_scan`), bootstrap from `NETWORK_SCAN_EMAILS` (authoritative, idempotent), exposed in the profile the gateway reads and in `/api/me`; internal check endpoint for the gateway; tests | none | [x] 2026-11-12, user-service `1681928` |
| NS-08 | user-service + gateway | Persist the scan mode in the scan history (user-service column and history payload; gateway sends it on register and reads it back) so `mode` survives a gateway restart. Added 2026-11-12: NS-03 keeps `mode` only in the in-memory `ScanOwnershipRegistry` | NS-03 | [x] 2026-11-12, user-service `3375c52`, gateway `98febf0` |

### Part 2: email report

| ID | Repo | Task | Depends on | Done |
|---|---|---|---|---|
| EM-01 | user-service | Report email rendering: HTML summary (target, date, mode, severity counts, top 10 findings) and plain-text alternative, JSON attachment identical to the browser export; pure functions with snapshot tests | none | [ ] |
| EM-02 | user-service | `Mailer` port with an SMTP adapter (`lettre`, STARTTLS 587) and an in-memory fake; when `update_scan_outcome` stores `completed`, send the report to the account email in the background, once per scan (`report_emailed_at` migration), bounded retry, never failing the update; SMTP unset disables sending; `report.emailed` and `report.email_failed` audit events; tests with the fake and a testcontainers SMTP sink (Mailpit) | EM-01 | [ ] |
| EM-03 | gateway | Expose the email status of a scan (`sent`, `failed`, `disabled`, `pending`) in the report and history payloads; OpenAPI; tests | EM-02 | [ ] |
| EM-04 | front | Report shows "Informe enviado a <email>" or why it was not sent; guards and mock; vitest and Playwright | EM-03 | [ ] |
| EM-05 | infra | SSM SecureStrings for the SMTP host, port, user and password (values set outside Terraform, like OAuth); user-service env; Mailpit in compose; README; tests | EM-02 | [ ] |

### Part 3: ready for Wazuh and Suricata

| ID | Repo | Task | Depends on | Done |
|---|---|---|---|---|
| SR-01 | broker | `siem.alert` event type: `source` (`wazuh`), payload `rule_id`, `rule_level` (0..15), `severity` (derived: low/medium/high/critical), `description`, `agent`, optional `src_ip`, `dest_ip`, `signature` (Suricata); examples and schema tests; decision record in `docs/decisions.md` | none | [ ] |
| SR-02 | gateway | `POST /api/integrations/siem/alerts`: bearer token from `SIEM_INGEST_TOKEN` (constant-time compare; 404 when unset), body size limit, rate limit, maps a Wazuh alert JSON to `siem.alert` and publishes with retry; fixtures from real Wazuh and Suricata alert samples; tests | SR-01 | [ ] |
| SR-03 | events-service | Aggregator: `siem_alerts` KPI (window) and a recent alerts feed by severity; series bucket count by severity; snapshot and delta; OpenAPI in the gateway fixture; tests | SR-01 | [ ] |
| SR-04 | front | Admin panel: "Alertas IDS" tab (AP-10 tabs) with unseen count, shown only when the snapshot says SIEM is enabled; guards and mock; vitest and Playwright | SR-03 | [ ] |
| SR-05 | infra | `siem_enabled` variable (default false): SSM token (random, like the events-service secret) and gateway env only when enabled; README section "Connecting Wazuh and Suricata": Wazuh manager custom integration (`integratord` script that POSTs to the endpoint), Suricata `eve.json` read by the Wazuh agent on the target, network mode as the traffic Suricata sees, sizing (manager and indexer need EC2, about 8 GB RAM); tests | SR-02 | [ ] |

Order:

1. NS-00 (spike), then NS-01, NS-07, NS-02, NS-03, NS-08, NS-05, NS-04, NS-06.
2. EM-01..EM-05 (independent of part 1; after open decision 2 and 3).
3. SR-01..SR-05.

## Branches

| Task | Repo | Branch |
|---|---|---|
| NS-00 | infra | `spike/network_scan_fargate` |
| NS-01 | broker | `feature/scan_mode_contract` |
| NS-02 | nmap-service | `feature/network_scan_executor` |
| NS-03 | gateway | `feature/network_scan_mode` |
| NS-04 | front | `feature/network_scan_mode` |
| NS-05 | infra | `feature/network_scan` |
| NS-06 | infra | lab check, no branch unless fixes are needed |
| NS-07 | user-service | `feature/network_scan_permission` |
| NS-08 | user-service, gateway | `feature/scan_history_mode` |
| EM-01 | user-service | `feature/report_email_render` |
| EM-02 | user-service | `feature/report_email_on_completion` |
| EM-03 | gateway | `feature/report_email_status` |
| EM-04 | front | `feature/report_email_status` |
| EM-05 | infra | `feature/smtp_config` |
| SR-01 | broker | `feature/siem_alert_contract` |
| SR-02 | gateway | `feature/siem_ingest` |
| SR-03 | events-service | `feature/siem_alerts_aggregate` |
| SR-04 | front | `feature/admin_siem_tab` |
| SR-05 | infra | `feature/siem_ready` |

## Acceptance criteria

- A user scans an allowed IP without any stored credential and gets a report with ports and version-based findings marked "patch state not verified".
- A network scan by an account outside `network_scan_emails`, or of a denylisted address, is rejected before anything is published.
- An `ssh` scan behaves exactly as before.
- When a scan completes, the user receives one email at the account address with an HTML summary and the JSON attached; the report shows whether it was sent; with SMTP unconfigured nothing is sent and the report says so.
- With `siem_enabled=false` nothing SIEM-related is deployed and the ingestion route answers 404.
- With it enabled, a Wazuh alert sample POSTed with the token appears in the admin panel "Alertas IDS" tab within seconds; a wrong token gets 401.

## Out of scope

- Deploying Wazuh, Suricata, OpenSearch or any EC2 for them.
- PDF reports.
- Free-form recipients and on-demand resend.
- Privileged scans in network mode (SYN scan, OS detection).

## Progress

- 2026-11-12: plan written after the effort evaluation. The user chose to start with IP-only scans and to leave the app ready for Wazuh and Suricata without deploying them.

- 2026-11-12: NS-00 local spike. `debian:bookworm-slim` + `nmap` 7.93 as uid 65532 (image 165 MB) ran `nmap -sT -sV --script vuln -T4 -oX -` against an `nginx:1.18` container with `--cap-drop ALL --memory 512m`: exit 0, 1 min 18 s, peak RSS 59 MB, port 80 `nginx 1.18.0` detected, NSE scripts ran (`http-vuln-cve2011-3192`, `http-csrf`, ...). No capability or memory change is needed (512 MB stays). Finding: `vulners` returned no CVEs. Its API (`https://vulners.com/api/v3/burp/software/`) answers `errorCode 401 "Nothing found"` without an API key, also with the upstream `vulners.nse`. This affects `ssh` mode too, so version-based CVEs need another source: the existing NVD enrichment by CPE (`MS_NMAP_NVD_ENRICHMENT_ENABLED`, off in Terraform) or a Vulners API key.

- 2026-11-12: the user chose NVD enrichment for both modes (see Decisions). NS-00 showed 512 MB is enough, so the memory change was dropped from NS-05.

- 2026-11-12: NS-01 done (route: delegated writer, 11 files). broker `feature/scan_mode_contract` `b6d478a`: `scan_mode` enum `ssh|network`, default `ssh`; `allOf` if/then/else requires `network_user`, `ssh_credentials_ref`, `has_sudo` in ssh mode and forbids them in network mode (decision D-16); `scan.requested` payload gets optional `scan_mode`; examples `contracts/examples/scan-request/` with invalid cases. RED 5 failing, GREEN `cargo test --lib` 47 passed and `make verify` exit 0 (parent spot check: 47 passed). Review: whole-branch candidate declined per policy.

- 2026-11-12: NS-07 done (route: delegated writer, 13 files, +689/-7). user-service `feature/network_scan_permission` `1681928`: migration `users.can_network_scan`, `NETWORK_SCAN_EMAILS` parsed like the admin list and applied authoritatively at startup and on `PUT /users/me` (first login of an unregistered email). No new endpoint: the gateway re-validates through the same `GET /users/me` that `require_admin` uses; the field is `can_network_scan` (bool, missing = false). Permission changes are not audited (ADR-015). RED: 23 compile errors; GREEN: `make verify` exit 0 with Docker suites (parent spot check: `cargo test` 99 passed). Review: medium, granted by the user, approved (lens reliability) and acknowledged; advisory R3-001: no test for the fail-closed startup path `WiringError::NetworkScanBootstrapFailed` (follow-up).

- 2026-11-12: NS-02 done (route: delegated writer, 19 files, +1414/-145; over the 400-line heuristic because the `ScanRequest` change touches every call site). nmap-service `feature/network_scan_executor` `36195a2` (domain `ScanAccess::Ssh|Network` with a contract-checked wire struct, `LocalNmapScanner` with argv `-sT -sV --script vuln -T<n> -oX - <ip>`, no shell, kill_on_drop, timeout `MS_NMAP_LOCAL_SCAN_TIMEOUT_SECS` default 900; pipeline routes by mode, network skips patch_verify, enrichment in both) and `65f3001` (debian:bookworm-slim pinned by digest + nmap, uid 65532, 216 MB; ADR-19). New reason codes `target_unreachable`, `nmap_timeout`, `nmap_io_error` (slug pattern, no broker change). RED: compile errors; GREEN: `make verify` exit 0 incl. `local_scan` ignored test against nginx:1.18 (parent spot check: 288 passed). Review: high, declined (user policy, not a permission task).
  - Notes for later tasks: "patch state not verified" is not stored in the scan result (`scanResult` has `additionalProperties: false`); NS-03/NS-04 derive it from the request's `scan_mode`. No `-Pn`: a host that drops probes to 80/443 reads as `target_unreachable`; NS-05 opens the target SG to the nmap-service SG, so lab targets answer with RST. NS-05 sets `MS_NMAP_LOCAL_SCAN_TIMEOUT_SECS` and keeps the SQS visibility timeout above it.

- 2026-11-12: NS-03 done (route: delegated writer, 29 files, +1743/-79). gateway `feature/network_scan_mode` `b96a6dc`, `40d61fd`. `POST /api/scans {target, mode?}`; network mode checks `can_network_scan` on `GET /users/me` first (403 `network_scan_not_permitted`, 503 `network_scan_permission_unavailable`), skips credentials, denylist then optional `NETWORK_SCAN_ALLOWED_CIDRS` (422 `network_scan_target_rejected` + `reason`: `target_loopback|target_link_local|target_multicast|target_broadcast|target_unspecified|target_outside_allowed_ranges`); `/api/me` adds `can_network_scan`; `GET /api/scans` entries add `mode`; ssh payload unchanged; D-18. RED: compile errors; GREEN: `make verify` exit 0 (parent spot check: `network_scan_mode` 20 passed). Review: high, granted by the user, 4 lenses, approved and acknowledged. Advisories fixed in a follow-up commit: IPv6 metadata `fd00:ec2::254` not denied, IPv4-compatible canonicalization mismatch, index-based event test, implicit ssh in `register`. Advisories left: `/api/me` now calls user-service on every request (falls back to false); rollout order (deploy nmap-service before the gateway, NS-06).
  - Gap: history `mode` is in memory only, so NS-08 was added. The front has hand-written types, guards and the contract-server mock, not an OpenAPI fixture (NS-04).

- 2026-11-12: NS-03 review follow-up gateway `008d456` (9 files, +110/-47): denylist adds `fc00::/7` as `target_unique_local`; one `canonical_target` (IPv4-mapped and IPv4-compatible, `::`/`::1` stay IPv6) and `check_target` returns the IP to publish; event test looks up by target; `register` renamed `register_ssh`. RED 3 failing; GREEN `make verify` exit 0 (parent spot check: 15 passed). Review: high, granted by the user, 4 lenses, approved and acknowledged. Advisories left: an allowlisted ULA range is still denied (accepted, the lab is IPv4); `denylisted()` assumes canonical input; could use `Ipv6Addr::is_unique_local`.

- 2026-11-12: NS-08 done (route: delegated writer, two repos). user-service `feature/scan_history_mode` (from develop) `3375c52`, 8 files +252/-11: migration `20261112130000_add_scan_history_mode.sql` (`scan_mode` NOT NULL DEFAULT 'ssh', CHECK), `POST /users/me/scans {target, scan_mode?}`, entries return `scan_mode`. gateway `feature/scan_history_mode` (from `feature/network_scan_mode`) `98febf0`, 5 files +195/-15: sends `scan_mode: "network"` only for network scans (ssh body unchanged), `GET /api/scans` reads mode from history, falls back to memory; restart test; D-19. RED: compile errors in both; GREEN: `make verify` exit 0 in both (parent spot check: user-service 90, gateway `network_scan_mode` 24 passed). Review: medium, under budget in both (no review due). Deploy order: user-service before gateway.

- 2026-11-12: NS-05 done (route: delegated writer in worktree `infra-worktrees/network_scan`, 15 files, +391/-25). infra `feature/network_scan` `e86be94`, `5ab0ce1`: `network_scan_emails` → `NETWORK_SCAN_EMAILS`, `network_scan_allowed_cidrs` → `NETWORK_SCAN_ALLOWED_CIDRS` (omitted when empty), `local_scan_timeout_secs` (900) → `MS_NMAP_LOCAL_SCAN_TIMEOUT_SECS`; NVD on with 86400 s cache; nmap-service in its own `${project}-nmap-sg` (egress all, no ingress), internal SG gets `mongo_from_nmap` 27017; SQS visibility `max(ssh, local) + 60` (970 by default); target scripts allow all TCP from the nmap SG; compose; README. RED: 5 terraform tests and 8 script checks failing; GREEN: `terraform test` 69 passed (parent spot check: 69 passed), script tests OK, shellcheck/tflint/fmt/validate OK. `make verify` stops at `check-paths.sh` in a worktree (sibling repos not next to it), known layout issue. Live plan skipped: lab credentials expired. Review: high, granted by the user, 4 lenses, approved and acknowledged. Follow-up commit for: NVD time not budgeted in the visibility timeout, missing `depends_on` on the Mongo rule, isolation tests weaker than their names, script abort path untested, and a README note that existing targets must be re-opened. Left: open default target range (accepted, academic allowlist of accounts), duplicated `allow_nmap` in both scripts, compose empty vs Terraform unset CIDRs.

- 2026-11-12: NS-04 done (route: delegated writer, 27 files, +1248/-84). front `feature/network_scan_mode` `e91e9fc` (types, guards, `getMe` fail-closed `can_network_scan`, contract server), `937af7f` (radio group "Modo de escaneo" shown only when allowed; IP-only field with a patch-not-verified hint; 403 handled without ending the session; messages per 422 reason and for 503; history "Modo" column with SSH / Solo IP / —; report mode line and a `role="note"` for IP-only, mode read from the history entry; friendly failure reasons `target_unreachable`, `nmap_timeout`, `nmap_io_error`), `380c6f0` (Playwright `network-scan-mode.spec.ts`). RED: 9 then 15 failing unit tests; GREEN: `npm run verify` exit 0 with 437 Vitest and 72 Playwright (parent spot check: 437 passed). Review: RDD disabled in front. Notes: a history entry with an unknown mode string fails the whole history guard (same strictness as status); IPv6 targets are not accepted client-side.

- 2026-11-12: NS-05 review follow-up infra `e09d2cf` (8 files, +100/-17): `nvd_enrichment_budget_secs` (300) in the visibility formula, so the default is 1270 s; `depends_on` on the Mongo rule; isolation tests enumerate every ingress rule; script test for a failed authorize; README note to re-run the target scripts on existing targets. RED via the new tests and temporary mutations; GREEN `terraform test` 71 passed (parent spot check: 71), script tests, shellcheck, tflint OK. Review: high, granted by the user, approved and acknowledged. Advisories left: nmap-service has no NVD timeout, so the budget is not enforced (follow-up in nmap-service); the visibility formula is repeated in a validation; the ingress rule list is duplicated in two test runs; a fractional budget passes validation. Cross-variable validation needs Terraform >= 1.9; `versions.tf` pins `~> 1.16.0`, so it is fine.

- 2026-11-16: user-service PR #15 (NS-07) conflicted after PR #14 (NS-08) merged. Merged `develop` into `feature/network_scan_permission` (`72d2553`): import conflicts in `src/repository.rs` and `tests/repository.rs` and the README API table combined from both sides; the NS-07 migration was renamed `20261112120000` → `20261112140000` so it sorts after the merged `scan_mode` migration (never deployed, so the rename is safe). `make verify` exit 0 (101 unit, Docker suites 56/56/4/2/1). PR #15 is now mergeable. Pushed: nmap-service `feature/network_scan_executor`, gateway `feature/network_scan_mode` and `feature/scan_history_mode`, front `feature/network_scan_mode`, infra `feature/network_scan` and `docs/network_scan_plan`.

- 2026-11-17: NS-06 lab deploy (route: inline, user-authorized, profile `learnerlab`). All PRs merged into `develop` (broker #7, user-service #14 #15, nmap-service #30, gateway #35 #36, front #37, infra #34 #35). `terraform apply` with `TF_VAR_network_scan_emails=["on.aguirre@duocuc.cl"]`: 5 added, 2 changed, 2 replaced (nmap SG, egress, `mongo_from_nmap`, task defs, SQS visibility). Services ignore `task_definition` changes, so user-service (:3) and nmap-service (:2) were rolled by hand; then `push-images.sh` in order user-service, nmap-service, gateway, front. `verify-stack.sh` 11 passed, 0 failed. `create-weak-target.sh` re-run (target SG opened to `security-app-nmap-sg`). Fargate check (closes the NS-00 open point): a `scan_mode: network` request published to SNS for `172.31.91.139` completed in about 1m40s, ports=4, vulnerabilities=41, log `modo network: se omite la verificación de parches`. Isolation: only `security-app-weak-target-sg` (tcp all) and `security-app-internal-sg` (tcp/27017) accept the nmap SG, so nmap-service cannot reach the gateway or Postgres. Pending (needs a Google login, not done): UI network scan with the authorized account, a non-authorized account not seeing the mode and getting 403, ssh scan regression. Lab paused afterwards at user request: `desired_count=0` (7 services, 0 tasks) and weak target destroyed (0 instances). RDD: the stop hook offered a whole-branch review against base 5e87410; declined (user policy).

## Next step

Part 1 complete (NS-06 UI checks passed on 2026-11-18 during UT-05 of `network-scan-url-target.md`). Part 2 (EM-01) next; SMTP provider resolved (Gmail, decision 3).