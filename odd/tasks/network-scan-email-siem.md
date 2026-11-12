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
- **Network mode is unprivileged.** It uses `nmap -sT -sV --script vuln` (TCP connect, no raw sockets, no `-O`), so it runs on Fargate without extra capabilities. There is no patch check, so findings keep `confidence=version_match` and the report says the patch state was not verified.
- **Network mode needs a target allowlist (not optional).** Today the stored credential is the de facto proof that the target is the user's. Without it, any user could scan any IP from AWS, which breaks the AWS acceptable-use policy. Network mode only accepts targets inside the allowed CIDR ranges, which are enforced in the gateway. Recommended source: a Terraform variable `network_scan_allowed_cidrs` (default: the VPC CIDR). Pending user confirmation (see Open decisions).
- **Email through a generic SMTP provider, not SES or SNS.** SES is denied in the lab, and SNS email only sends plain text with no attachment and needs a subscription confirmation per address. user-service sends the email with an SMTP client (`lettre`). It already owns the user's email and the stored result. SMTP host, port, user and password come from SSM; with no host configured, email is disabled and the API answers 503. Port 587 with STARTTLS (AWS only throttles 25). The lab uses a test inbox provider (for example Mailtrap); production can use any SMTP provider.
- **An email always goes to the user's own address.** It goes to the account's email only, never to a free-form recipient, so the feature cannot be used to send spam. Body: an HTML summary (target, date, severity counts, top findings). Attachment: the same JSON the browser exports today. Sending is rate limited per user.
- **SIEM-ready means seams, not services.** No Wazuh, Suricata or EC2 for them in this plan. The app gets:
  - a `siem.alert` event type in the broker contract;
  - an authenticated ingestion endpoint that a Wazuh integration can POST alerts to;
  - an aggregator and panel view for those alerts;
  - feature flags so all of it is off by default;
  - a document describing how to connect a Wazuh manager and Suricata later.
- **The ingestion endpoint lives in the gateway**, which is already the only public entry point and a Kinesis producer. Route: `POST /api/integrations/siem/alerts`. Auth: a bearer token stored in SSM, compared in constant time. With no token configured the route returns 404, so it is off by default. It is rate limited. It maps a Wazuh alert (rule level, rule id, description, agent, source and destination IP, and Suricata `data.alert.signature` when present) into the `siem.alert` payload and publishes it with the existing retry policy (AP-07).

## Open decisions

1. Allowlist source for network mode. Recommended: `network_scan_allowed_cidrs` in Terraform, enforced by the gateway. The alternative is admin-managed ranges in user-service with a UI, which costs more and adds runtime changes.
2. Email trigger. Recommended: a "Enviar por correo" button on the report. Sending automatically on scan completion as a per-user preference would be a later task.
3. SMTP provider for the lab (Mailtrap sandbox recommended, so no real mail leaves the lab).

## Constraints

- Strict TDD (user global config): RED before GREEN in every task.
- `ssh` mode keeps its current behavior and payloads; contract changes are additive.
- New API fields go to the OpenAPI, the front guards and the contract-server mock.
- Learner Lab: no SES. nmap-service runs as `LabRole` on Fargate. More memory costs credit.
- Artifacts in English, Conventional Commits, no attribution.
- One branch per task, cut from `develop`; PRs target `develop`.

## Tooling

- Runners: front `npm run verify` and Playwright; Rust services `make verify`; broker contract tests; infra `make verify`.
- Review: per stored user policy, decline reviews except tasks touching permissions or secrets: NS-03 (allowlist enforcement), EM-02 (SMTP secret and recipient rule), SR-02 (ingestion token).

## Checklist

### Part 1: network scan (IP only)

| ID | Repo | Task | Depends on | Done |
|---|---|---|---|---|
| NS-00 | infra | Lab spike: run `nmap -sT -sV --script vuln` from a Fargate task (nmap-service image plus nmap) against the weak target's private IP; record duration, memory peak and findings compared with `ssh` mode; open target SG ingress from `internal-sg` | none | [ ] |
| NS-01 | broker | `scan-request` contract: `scan_mode` (`ssh` default, `network`); `network_user` and `ssh_credentials_ref` required only when `ssh` (JSON Schema if/then); `scan.requested` event payload carries the mode; examples and tests | none | [ ] |
| NS-02 | nmap-service | Local executor that runs nmap in the container (`-sT -sV --script vuln -T<n> -oX -`, no `-O`, no sudo); pipeline picks the executor by mode; network mode skips the patch check and records why; nmap in the image; parser reused; timeouts and reason codes (`target_unreachable`); unit tests and a testcontainers test against a local target | NS-01 | [ ] |
| NS-03 | gateway | `POST /api/scans` accepts `mode`; `network` skips credential resolution and requires the target inside `NETWORK_SCAN_ALLOWED_CIDRS` (403 with a reason otherwise; empty list means network mode is off); `ssh` unchanged; publishes the new contract; OpenAPI; tests | NS-01 | [ ] |
| NS-04 | front | Scan form: mode choice (SSH credentials or IP only), IP-only explains that patch state is not verified; mode shown in history and report; 403 allowlist message; guards and contract-server mock; vitest and Playwright | NS-03 | [ ] |
| NS-05 | infra | `network_scan_allowed_cidrs` variable (default: the default VPC CIDR) to the gateway env; nmap-service memory to 1024 MB if NS-00 shows it is needed; `create-test-target.sh` and `create-weak-target.sh` open the target SG to `internal-sg`; compose; tests and README | NS-00 | [ ] |
| NS-06 | infra | Lab deploy and check: network scan of the weak target from the UI; ssh scan still works; a target outside the allowlist is rejected | NS-02..NS-05 | [ ] |

### Part 2: email report

| ID | Repo | Task | Depends on | Done |
|---|---|---|---|---|
| EM-01 | user-service | Report email rendering: HTML summary (target, date, mode, severity counts, top 10 findings) and plain-text alternative, JSON attachment identical to the browser export; pure functions with snapshot tests | none | [ ] |
| EM-02 | user-service | `Mailer` port with an SMTP adapter (`lettre`, STARTTLS 587) and an in-memory fake; `POST /users/me/scans/{id}/report/email` sends to the account email only; 404 for another user's scan, 409 if not completed, 503 if SMTP is not configured, 429 over the per-user limit; `report.emailed` audit event; tests with the fake and a testcontainers SMTP sink (MailHog or Mailpit) | EM-01 | [ ] |
| EM-03 | gateway | Proxy `POST /api/scans/:id/report/email` behind the session; OpenAPI; tests | EM-02 | [ ] |
| EM-04 | front | "Enviar por correo" button in the report with sending, sent and error states (503 disabled, 429 retry later); guards and mock; vitest and Playwright | EM-03 | [ ] |
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

1. NS-00 (spike), then NS-01, NS-02, NS-03, NS-05, NS-04, NS-06.
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
| EM-01 | user-service | `feature/report_email_render` |
| EM-02 | user-service | `feature/report_email_send` |
| EM-03 | gateway | `feature/report_email_proxy` |
| EM-04 | front | `feature/report_email_button` |
| EM-05 | infra | `feature/smtp_config` |
| SR-01 | broker | `feature/siem_alert_contract` |
| SR-02 | gateway | `feature/siem_ingest` |
| SR-03 | events-service | `feature/siem_alerts_aggregate` |
| SR-04 | front | `feature/admin_siem_tab` |
| SR-05 | infra | `feature/siem_ready` |

## Acceptance criteria

- A user scans an allowed IP without any stored credential and gets a report with ports and version-based findings marked "patch state not verified".
- A network scan of an IP outside the allowlist is rejected before anything is published.
- An `ssh` scan behaves exactly as before.
- From a completed report, the user receives an email at the account address with an HTML summary and the JSON attached; with SMTP unconfigured the button explains email is unavailable.
- With `siem_enabled=false` nothing SIEM-related is deployed and the ingestion route answers 404.
- With it enabled, a Wazuh alert sample POSTed with the token appears in the admin panel "Alertas IDS" tab within seconds; a wrong token gets 401.

## Out of scope

- Deploying Wazuh, Suricata, OpenSearch or any EC2 for them.
- PDF reports.
- Automatic email on completion and free-form recipients.
- Privileged scans in network mode (SYN scan, OS detection).

## Progress

- 2026-11-12: plan written after the effort evaluation. The user chose to start with IP-only scans and to leave the app ready for Wazuh and Suricata without deploying them.

## Next step

Answer open decision 1 (allowlist source), then NS-00 in the lab and NS-01 in broker.
