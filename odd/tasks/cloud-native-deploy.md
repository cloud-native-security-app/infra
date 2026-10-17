# Cloud-native deploy of security-app (MASTER PLAN)

Self-contained: any AI agent can start from this file with no prior context.
Feature id: `cloud-native-deploy` | Engram topic: `odd/cloud-native-deploy/tasks` (project: infra) | Branch: `v1`

## Objective

Move `security-app` from manual, imperative AWS bash scripts to a reproducible cloud-native
deploy: Terraform for shared infrastructure, GitHub Actions per service repo for images and
rollouts, and RabbitMQ replaced by AWS-managed SNS + SQS (decision 2026-10-17; Amazon MQ is denied in the Learner Lab).

## Problem

- 22 manual bash scripts in `deploy/aws/` (numbered `00`..`99`) create AWS resources imperatively.
- Intermediate state lives in `deploy/aws/.state/*.txt` (IDs/ARNs, plus `google_oauth.env` with secrets). No real state backend, no drift detection.
- No CI in any service repo: images are built and pushed by hand (`05`, `07`, `17`).
- Task definitions are registered by `sed`-templating JSON in `deploy/aws/task-defs/` (`09`, `16`).

## Why

Repeatable environments, reviewable infra changes (`terraform plan`), automated image build and
deploy per service, and a cloud-native messaging layer on managed services (no broker container to operate).

## Decisions

| Decision | Rationale |
|---|---|
| No root repo; sibling repo `infra` owns shared infra | The old root folder `security-app/` is not a real repo (empty `.git`). Service repos stay independent under `cloud-native-security-app/*`; shared infra needs its own home. |
| Messaging moves from RabbitMQ to **AWS SNS + SQS** (2026-10-17, user decision) | Goal: demonstrate a cloud-native architecture on managed services. Amazon MQ is denied in the Learner Lab (every `mq:*` call returns AccessDenied, spike 1); SQS/SNS are allowed (queue, redrive DLQ, topic, filtered subscription, publish verified). Kafka stays rejected. Proposed topology: `broker` : `odd/tasks/sqs-sns-migration.md` (status Proposed). |
| Accepted tradeoffs of SQS/SNS | (1) gateway and nmap-service replace `lapin` (AMQP) with `aws-sdk-sqs` / `aws-sdk-sns`; (2) tests move from testcontainers RabbitMQ to LocalStack (real containers, no mocks); (3) the `broker` repo is retired as a broker, its topology moves to Terraform in `infra` and its JSON Schema contracts stay; (4) local docker-compose gains LocalStack; (5) the lab CA baked into nmap-service is dropped (public-CA HTTPS); (6) at-least-once delivery, 256 KB limit, no ordering on standard queues, SSH credentials travel in `scan.requests` (encrypt at rest, short retention). |
| Gateway stays a Rust ECS service; its redesign is **DEFERRED** | Open question. AWS API Gateway alone cannot do gateway's Google OAuth, session handling, profile provisioning and post-login redirect. The user will rethink it; this plan only covers its CI/CD and its messaging adapter rewrite (lapin -> AWS SDK), not the redesign. |
| Terraform for infra, GitHub Actions per service repo for images | Clear split: infra changes rarely, images change per commit. |
| Work on branch `v1` in every repo | User decision. |

## Constraints

- AWS Academy Learner Lab: no `iam:CreateRole`, so no GitHub OIDC; reuse the existing `LabRole` (already used as `EXEC_ROLE_NAME` in `deploy/aws/00-env.sh`).
- **Shared `LabRole`, no per-service least privilege.** Every ECS task (execution and task role) uses `LabRole`, so the per-service RabbitMQ users/ACLs of the old broker have no equivalent. Accepted tradeoff (2026-10-17). Mitigation: resource-level SQS queue policies and SNS topic policies. `LabRole` access to SQS/SNS from inside a running ECS task is verified (spike 7, 2026-10-17).
- Cloud Map namespace (`security-app.local`) must be created via the ECS cluster `service_connect_defaults`, not as a standalone namespace.
- Learner Lab credentials are temporary. They are refreshed into GitHub secrets before each deploy (accepted by the user; helper: `refresh-gh-secrets.sh`, task TF-14).
- Never commit `deploy/aws/.state/` or any `*.tfstate` (gitignored).

## Target layout

| Repo | Owns |
|---|---|
| `infra` | Terraform: S3 backend, SGs, ALB + HTTPS, ECR x4, ECS cluster + Service Connect namespace, log groups, SNS topics + SQS queues + DLQs + subscriptions + queue policies (messaging), postgres/mongo services, ECS service shells for app services, outputs; `refresh-gh-secrets.sh`; this master plan; legacy `deploy/aws/` scripts until parity |
| `broker` | Messaging design and tests: proposed SNS/SQS topology (implemented by `infra` TF-10), JSON Schema contracts, LocalStack setup and tests; retired as a broker (RabbitMQ image and definitions removed) |
| `user-service` | `.aws/task-definition.json`, `ci.yml`, `deploy.yml` |
| `nmap-service` | same as user-service; lab CA dropped; messaging adapter rewritten to AWS SDK (`sqs-sns-adapter`) |
| `front` | same; `VITE_GATEWAY_BASE_URL` from repo variable |
| `gateway` | CI/CD + messaging adapter rewrite (lapin -> AWS SDK); redesign deferred |

Ownership rule: Terraform creates ECS services with a **bootstrap task definition** and
`lifecycle { ignore_changes = [task_definition] }`. Each service's CI owns task-definition revisions afterwards.

## Cross-repo task index

| ID | Repo | Feature doc (repo + path) | Engram topic | Status |
|---|---|---|---|---|
| TF-01..TF-17 | infra | `infra` : `odd/tasks/terraform-infra.md` | `odd/terraform-infra/tasks` | planned |
| MSG-01..MSG-09 | broker | `broker` : `odd/tasks/sqs-sns-migration.md` | `odd/sqs-sns-migration/tasks` | planned (topology signed off 2026-10-17, MSG-01 done) |
| MSG-GW-01..MSG-GW-04 | gateway | `gateway` : `odd/tasks/sqs-sns-adapter.md` | `odd/sqs-sns-adapter/tasks` (project: gateway) | planned |
| MSG-NM-01..MSG-NM-05 | nmap-service | `nmap-service` : `odd/tasks/sqs-sns-adapter.md` | `odd/sqs-sns-adapter/tasks` (project: nmap-service) | planned |
| MQ-* | broker | `broker` : `odd/tasks/amazon-mq-migration.md` | `odd/amazon-mq-migration/tasks` | superseded 2026-10-17 by MSG-*; MQ-01 spike result kept |
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
| 1 | Feasibility spikes (below) and messaging topology sign-off (MSG-01) | Each spike has a recorded yes/no and fallback decision |
| 2 | Terraform (TF-*) | `plan` clean and idempotent; stack reachable |
| 3 | CI/CD and messaging (CI-*, MSG-*, MSG-GW-*, MSG-NM-*) | CI green on PR; `deploy.yml` rollout stable |

Phase 1 spikes:

1. Amazon MQ is allowed in the Learner Lab. **Result 2026-10-17: NO**. Every `mq:*` call is denied for the `voclabs` role in us-east-1 and us-west-2 (see broker MQ-01 in `odd/tasks/amazon-mq-migration.md`). SQS + SNS are allowed (queue, redrive DLQ, topic, queue policy, filtered subscription with raw delivery, publish verified 2026-10-17). **Decision: SQS + SNS.**
2. ~~Quorum queues + `x-delivery-limit` on Amazon MQ~~ Superseded 2026-10-17 (replaced by `RedrivePolicy.maxReceiveCount`, covered by broker MSG-06).
3. ~~Definitions import via management API~~ Superseded 2026-10-17 (topology is Terraform, TF-10).
4. ~~AMQPS public CA / drop baked lab CA~~ Superseded 2026-10-17 (SQS/SNS use public-CA HTTPS; lab CA dropped in nmap-service MSG-NM-05).
5. S3 bucket available for Terraform state.
6. `LabRole` can read SSM / Secrets Manager for OAuth secrets.
7. **New:** `LabRole` can use SQS and SNS from inside a running ECS Fargate task (send, receive, delete, change visibility, publish; SSE-SQS vs KMS). Tracked as broker MSG-02. **Result 2026-10-17: YES.** A Fargate task (image `public.ecr.aws/aws-cli/aws-cli`, task and execution role `LabRole`, default VPC with public IP) ran as `assumed-role/LabRole` and passed: SNS publish with a `routing_key` attribute, SQS receive through the raw-delivery subscription, change-visibility, send to the DLQ, delete, get-attributes, all on SSE-SQS queues. Test resources deleted afterwards. Gotchas: the first `run-task` in a fresh account fails until the ECS service-linked role propagates (retry); a deleted queue name cannot be reused for 60 s.

## Out of scope

- Gateway redesign (deferred) and replacing it with AWS API Gateway.
- Kafka, RabbitMQ (self-managed or Amazon MQ) or any non-AWS-managed broker.
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
- End-to-end scan flows through SNS + SQS (user-service -> gateway -> nmap-service result), including a DLQ check (a message lands in the DLQ after 3 receives).
- CI green on a PR in each service repo.
- `deploy.yml` produces a stable ECS rollout (services-stable).

## Progress

- [x] Phase 0: `infra` repo created on `v1`; `deploy/`, compose, START.md imported (no `.state/`, no `*.sh.new`).
- [x] Phase 0: master plan and `terraform-infra` doc written.
- [x] Phase 0: per-repo feature docs and harness migration H1-H5 (all repos on `v1`, verify green). Follow-up: broker needs a GGA-rules `AGENTS.md`.
- [x] R1 root cleanup: root `.git` and copied files removed; `.state/` moved to `infra/deploy/aws/.state/` (gitignored).
- [x] 2026-10-17: spike 1 recorded (Amazon MQ denied; SQS/SNS allowed). User decision: SQS + SNS replaces RabbitMQ. Messaging plans written (`broker` MSG-*, `gateway` and `nmap-service` `sqs-sns-adapter`); TF-10 replaced.
- [ ] Phases 1-3.

## Next step

MSG-01 is done (topology signed off 2026-10-17 in `broker` : `odd/tasks/sqs-sns-migration.md`). Spike 7 passed (2026-10-17). Next: the remaining Phase 1 spikes (5: S3 state bucket, 6: LabRole SSM/Secrets Manager) before any Terraform work; broker MSG-03 (LocalStack) can run in parallel.
