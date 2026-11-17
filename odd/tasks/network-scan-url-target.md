# Network scan by URL or hostname

## Objective

A network-mode scan (`scan_mode: network`, no credentials) accepts a URL or a hostname (for example `https://app.example.com:8443/login`) as well as an IP. The whole host is scanned: nmap's default ports plus the URL port when it is not a default one.

## Problem

Network mode only accepts an IPv4/IPv6 address today. Users know their targets by name, and a URL often carries a non-default port that the default nmap port set does not cover.

## Why

It makes IP-only scanning usable for real targets without asking the user to resolve DNS by hand, and it keeps the URL port in the scan.

## Scope

- broker: `scan-request` gains two optional network-only fields, `target_host` (the hostname as typed, for display and HTTP virtual hosts) and `extra_port` (the URL port, 1..65535). `ip` stays required and stays the address actually scanned.
- nmap-service: accepts both fields. The network scan covers nmap's default ports plus `extra_port`. When `target_host` is present it is passed as the HTTP host for the scripts (`http.host`). SSH mode is unchanged and stays IP-only.
- gateway: in network mode `target` may be an IP, a hostname, or an `http`/`https` URL. The gateway parses it (host and port; the path and query are ignored; userinfo is rejected), resolves the host with a timeout, checks every resolved address against the existing denylist and optional allowlist, pins one address (IPv4 first) and publishes it as `ip`, with `target_host` and `extra_port`. History stores the hostname as typed by the user (without path). Security events keep the IP.
- front: in network mode the target field accepts an IP, a hostname, or a URL, with its own validator (the SSH and credential forms keep the IP validator). History and report show the hostname.
- Lab check together with the pending NS-06 UI checks.

## Constraints

- Strict TDD (session config). Runners: `make verify` in the Rust repos and broker, `npm run verify` and Playwright in front.
- DNS rebinding: nmap never resolves the name. The gateway publishes the pinned IP, and nmap scans that IP.
- Every resolved address must pass the policy. If one fails, the request fails (422), so a name cannot hide a denied address behind an allowed one.
- Name and argv safety: hostnames are validated against RFC 1123 labels (letters, digits, hyphen, dots, at most 253 characters, no leading hyphen) before they reach the contract or nmap's argv.
- Deploy order: nmap-service before the gateway, because the gateway will publish the new fields.
- Known and accepted, not changed here: the denylist does not block RFC 1918 ranges, because the lab target is a private VPC address. A hostname that resolves to a private address is therefore allowed for an authorized account, the same as typing that IP.

## Tasks

| ID | Repo | Task | Depends on | Done |
|---|---|---|---|---|
| UT-01 | broker | `scan-request` schema: optional `target_host` (RFC 1123 hostname pattern, max 253) and `extra_port` (integer 1..65535), allowed only when `scan_mode` is `network`; `scan.requested` event payload gains optional `target_host`; valid and invalid examples; schema tests | none | [ ] |
| UT-02 | nmap-service | `ScanRequest` accepts `target_host` and `extra_port`; network-mode argv covers the default ports plus `extra_port` (verify the exact nmap flags against the real binary) and passes `http.host` when `target_host` is set; contract parity tests; unit tests on the argv; testcontainers test still green | UT-01 | [ ] |
| UT-03 | gateway | Network `target` parser (IP, hostname, `http`/`https` URL; default ports 80/443; extra port only when it is not in nmap's default set or always sent, decided in the task and recorded); resolver port with a timeout (real adapter on `tokio::net::lookup_host`, fake in tests); policy over every address; pin IPv4 first; publish `target_host` and `extra_port`; history target is the hostname; new 422 reasons `target_unresolvable` and `target_resolves_to_denied`; OpenAPI; tests | UT-01 | [ ] |
| UT-04 | front | Network-mode validator for IP, hostname, or URL; help text; 422 messages for the new reasons; history and report show the hostname; contract-server mock; vitest and Playwright | UT-03 | [ ] |
| UT-05 | infra | Lab deploy and check: a network scan by URL of the weak target (by its private DNS name) completes; a name that resolves to a denied address gets 422; plus the pending NS-06 UI checks | UT-02..UT-04 | [ ] |

Order: UT-01, UT-02, UT-03, UT-04, UT-05.

## Branches

| Task | Repo | Branch |
|---|---|---|
| UT-01 | broker | `feature/scan_target_host` |
| UT-02 | nmap-service | `feature/scan_target_host` |
| UT-03 | gateway | `feature/scan_target_url` |
| UT-04 | front | `feature/scan_target_url` |
| UT-05 | infra | lab check, no branch unless fixes are needed |
| plan | infra | `docs/network_scan_url_plan` |

## Acceptance criteria

- An authorized user types `https://<host>:8443/path` in network mode. The scan covers the default ports and 8443, and history shows `<host>`.
- A hostname that does not resolve gets 422 `target_unresolvable`. A hostname with any resolved address in the denylist, or outside the allowlist when one is set, gets 422 `target_resolves_to_denied`. Nothing is published in either case.
- An IP target behaves exactly as before. SSH mode is unchanged.
- nmap never receives a hostname as its scan target.

## Applicable checks

- broker, nmap-service, gateway: `make verify`.
- front: `npm run verify` and the Playwright specs it covers.
- Lab: `scripts/verify-stack.sh` and the manual checks in UT-05.

## Delivery

Forecast about 1,200 authored changed lines across four repos, one PR per repo (each near or under 400). Strategy: `ask-on-risk`.

## Progress

- 2026-11-17: plan created after mapping (broker schemas, gateway `submit_scan`, `network_scan.rs`, nmap-service `local_scanner.rs`, user-service `scan_history.target TEXT`, front `validateScanTarget.ts`). User decision: scan the whole host, not only the URL port.
- Pending from the same session, not part of this plan: the scan page SSE fixes (keep-alive, replay of the current state on reconnect, `cancelled` status, cancel button on the scan page, ALB idle timeout). Proposed to the user, no answer yet.

## Next step

UT-01 in broker.
