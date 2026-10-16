# Cloud-native deploy of security-app (MASTER PLAN)

Self-contained: any AI agent can start from this file with no prior context.
Feature id: `cloud-native-deploy` | Engram topic: `odd/cloud-native-deploy/tasks` (project: infra) | Branch: `v1`

## Objective

Move `security-app` from manual, imperative AWS bash scripts to a reproducible cloud-native
deploy: Terraform for shared infrastructure, GitHub Actions per service repo for images and
rollouts, and RabbitMQ replaced by Amazon MQ for RabbitMQ (managed).

## Problem

- 22 manual bash scripts in `deploy/aws/` (numbered `00`..`99`) create AWS resources imperatively.
- Intermediate state lives in `deploy/aws/.state/*.txt` (IDs/ARNs, plus `google_oauth.env` with secrets). No real state backend, no drift detection.
- No CI in any service repo: images are built and pushed by hand (`05`, `07`, `17`).
- Task definitions are registered by `sed`-templating JSON in `deploy/aws/task-defs/` (`09`, `16`).

## Why

Repeatable environments, reviewable infra changes (`terraform plan`), automated image build and
deploy per service, and no self-managed broker container to operate.

## Decisions

| Decision | Rationale |
|---|---|
| No root repo; sibling repo `infra` owns shared infra | The old root folder `security-app/` is not a real repo (empty `.git`). Service repos stay independent under `cloud-native-security-app/*`; shared infra needs its own home. |
| Only RabbitMQ migrates, to **Amazon MQ for RabbitMQ** | The broker relies on quorum queues, `x-delivery-limit`, dead-letter exchanges (DLX) and topic routing. Kafka has no per-message retry/DLQ semantics and would force rewriting the AMQP code in gateway and nmap-service. Amazon MQ keeps AMQP, so application code stays. |
| Gateway stays a Rust ECS service; its redesign is **DEFERRED** | Open question. AWS API Gateway alone cannot do gateway's Google OAuth, session handling, profile provisioning and post-login redirect. The user will rethink it; this plan only covers its CI/CD and MQ endpoint config. |
| Terraform for infra, GitHub Actions per service repo for images | Clear split: infra changes rarely, images change per commit. |
| Work on branch `v1` in every repo | User decision. |

## Constraints

- AWS Academy Learner Lab: no `iam:CreateRole`, so no GitHub OIDC; reuse the existing `LabRole` (already used as `EXEC_ROLE_NAME` in `deploy/aws/00-env.sh`).
- Cloud Map namespace (`security-app.local`) must be created via the ECS cluster `service_connect_defaults`, not as a standalone namespace.
- Learner Lab credentials are temporary. They are refreshed into GitHub secrets before each deploy (accepted by the user; helper: `refresh-gh-secrets.sh`, task TF-14).
- Never commit `deploy/aws/.state/` or any `*.tfstate` (gitignored).

## Target layout

| Repo | Owns |
|---|---|
| `infra` | Terraform: S3 backend, SGs, ALB + HTTPS, ECR x4, ECS cluster + Service Connect namespace, log groups, Amazon MQ broker, postgres/mongo services, ECS service shells for app services, outputs; `refresh-gh-secrets.sh`; this master plan; legacy `deploy/aws/` scripts until parity |
| `broker` | `definitions.json` import into Amazon MQ (management API), local RabbitMQ image kept for docker-compose |
| `user-service` | `.aws/task-definition.json`, `ci.yml`, `deploy.yml` |
| `nmap-service` | same as user-service; drops baked lab CA if spike passes |
| `front` | same; `VITE_GATEWAY_BASE_URL` from repo variable |
| `gateway` | CI/CD + MQ endpoint config only; redesign deferred |

Ownership rule: Terraform creates ECS services with a **bootstrap task definition** and
`lifecycle { ignore_changes = [task_definition] }`. Each service's CI owns task-definition revisions afterwards.

## Cross-repo task index

| ID | Repo | Feature doc (repo + path) | Engram topic | Status |
|---|---|---|---|---|
| TF-01..TF-17 | infra | `infra` : `odd/tasks/terraform-infra.md` | `odd/terraform-infra/tasks` | planned |
| MQ-* | broker | `broker` : `odd/tasks/amazon-mq-migration.md` | `odd/amazon-mq-migration/tasks` | planned |
| CI-* | user-service | `user-service` : `odd/tasks/ci-cd-deploy.md` | `odd/ci-cd-deploy/tasks` (project: user-service) | planned |
| CI-* | nmap-service | `nmap-service` : `odd/tasks/ci-cd-deploy.md` | `odd/ci-cd-deploy/tasks` (project: nmap-service) | planned |
| CI-* | front | `front` : `odd/tasks/ci-cd-deploy.md` | `odd/ci-cd-deploy/tasks` (project: front) | planned |
| CI-* | gateway | `gateway` : `odd/tasks/ci-cd-deploy.md` | `odd/ci-cd-deploy/tasks` (project: gateway) | planned |
| H1-H5 | all 5 service repos | Harness migration: remove legacy agent harness (`CLAUDE.md`, `CHECKPOINTS.md`, `feature_list.json`, `init.sh`, `progress/`, `.claude/`, non-gentle `AGENTS.md`), preserve knowledge in README/docs/Makefile `verify` | n/a (commit `chore: replace legacy agent harness with gentle-ai conventions`) | done |
| R1 | root `security-app/` | Root folder cleanup: remove empty root `.git` and copied files; move `.state/` to `infra/` untracked | n/a | done (2026-10-16) |

Service repos live under `cloud-native-security-app/{broker,front,gateway,nmap-service,user-service}`.

## Phases

| Phase | Content | Exit criterion |
|---|---|---|
| 0 | Harness migration (H1-H5) and publish plans | Plans committed on `v1` in all repos; legacy harness gone |
| 1 | Feasibility spikes (below) | Each spike has a recorded yes/no and fallback decision |
| 2 | Terraform (TF-*) | `plan` clean and idempotent; stack reachable |
| 3 | CI/CD (CI-*, MQ-*) | CI green on PR; `deploy.yml` rollout stable |

Phase 1 spikes:

1. Amazon MQ is allowed in the Learner Lab.
2. Quorum queues + `x-delivery-limit` work on the available engine version and deployment mode; fallback: classic queues + DLX/TTL, or `CLUSTER_MULTI_AZ`.
3. Definitions import via management API `POST /api/definitions`.
4. AMQPS on 5671 uses a public CA, so the baked lab CA in nmap-service can be dropped.
5. S3 bucket available for Terraform state.
6. `LabRole` can read SSM / Secrets Manager for OAuth secrets.

## Out of scope

- Gateway redesign (deferred) and replacing it with AWS API Gateway.
- Kafka or any broker other than Amazon MQ for RabbitMQ.
- GitHub OIDC / new IAM roles (not possible in Learner Lab).
- Creating GitHub remotes, pushes, PRs (user decisions).
- Migrating postgres/mongo to managed services (RDS/DocumentDB).

## Workflow notes

- gentle-ai Organic Driven Development: one feature doc per repo in `odd/tasks/`, mirrored to Engram.
- Strict TDD: observe RED before implementing. Runners: Terraform `fmt -check`/`validate`/`plan`; workflows `actionlint`; `cargo test` (Rust repos); `npm test` (front).
- Delivery strategy: `ask-on-risk`; about 400 authored changed lines per PR slice.
- Conventional Commits, no AI attribution. Push, PR creation and merge are user decisions.

## Verification (end state)

- `terraform fmt -check`, `terraform validate`, `terraform plan` (second plan shows no changes).
- `deploy/aws/14-verify.sh` equivalent checks: gateway `/health`, OpenAPI endpoint, `/auth/login` returns 302, front returns 200.
- End-to-end scan flows through Amazon MQ (user-service -> gateway -> nmap-service result).
- CI green on a PR in each service repo.
- `deploy.yml` produces a stable ECS rollout (services-stable).

## Progress

- [x] Phase 0: `infra` repo created on `v1`; `deploy/`, compose, START.md imported (no `.state/`, no `*.sh.new`).
- [x] Phase 0: master plan and `terraform-infra` doc written.
- [x] Phase 0: per-repo feature docs and harness migration H1-H5 (all repos on `v1`, verify green). Follow-up: broker needs a GGA-rules `AGENTS.md`.
- [x] R1 root cleanup: root `.git` and copied files removed; `.state/` moved to `infra/deploy/aws/.state/` (gitignored).
- [ ] Phases 1-3.

## Next step

Finish harness migration and per-repo plan docs, then run the Phase 1 spikes (start with spike 1, Amazon MQ availability in the Learner Lab) before any Terraform work.
