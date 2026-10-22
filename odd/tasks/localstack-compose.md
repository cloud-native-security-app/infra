# Feature: localstack-compose

Parent: `odd/tasks/terraform-infra.md` (open follow-up 1 of TF-17).
Engram topic for this doc: `odd/localstack-compose/tasks` (project: infra). Branch: `feature/localstack_compose` (from `origin/develop` 37f9545).

## Objective

Local development via `docker-compose.yml` uses LocalStack (SNS + SQS) instead of RabbitMQ, mirroring `terraform/messaging.tf`, and `START.md` section B describes that flow.

## Problem

gateway (b088b92) and nmap-service (0f42e1f) dropped AMQP and now talk SNS/SQS. The compose still runs RabbitMQ and passes retired `BROKER_*` / `MS_NMAP_BROKER_*` variables, so neither service can start locally.

## Why

Local runs must match production messaging. nmap-service's config test asserts the retired `BROKER_*` variables are not read.

## Scope

In: `docker-compose.yml`, a LocalStack init script (topics, queues, DLQs, redrive, subscriptions), its offline test, Makefile/`check-paths.sh` wiring, `START.md` section B, closing the follow-up.
Out: service code, Terraform, `push-images.sh` (still passes an optional, now unused `tls` build context; tracked as a gap).

## Constraints

- Topology mirrors `terraform/messaging.tf`: topics `scan-requests`, `scan-cancellations`, `scan-outcomes`; queues `ms-nmap-scan-requests`, `ms-nmap-scan-cancellations`, `gateway-scan-outcomes`, each with `<name>-dlq` and redrive `maxReceiveCount=3`; SNS->SQS subscriptions with `RawMessageDelivery=true`; `gateway-scan-outcomes` filtered on `routing_key` prefix `scan.outcome.`; requests visibility timeout = connect + command + 60.
- Services read `AWS_ENDPOINT_URL` (gateway `ENV_AWS_ENDPOINT_URL`, nmap-service `AWS_ENDPOINT_URL_VAR`) plus `AWS_REGION`; dummy credentials `test`/`test`.
- Image `localstack/localstack:4.4`; init hook in `/etc/localstack/init/ready.d/`.
- Init script is idempotent. Commits: Conventional Commits, no attribution. Artifacts in English, START.md in neutral Spanish.

## Tooling

- TDD mode: on (source: user global config "Strict TDD Mode: enabled").
- Runner: `bash scripts/test-localstack-init.sh`, `make verify`, `docker compose config -q`.
- Route per task: delegated writer (single bounded writer).

## Checklist

| ID | Task | Done |
|---|---|---|
| LS-01 | `scripts/localstack-init.sh` + `scripts/test-localstack-init.sh` (RED first), wired into `make verify` | [x] |
| LS-02 | Rework `docker-compose.yml`: LocalStack service with healthcheck, service env, drop RabbitMQ/BROKER/TLS; compose assertions in the test, `check-paths.sh` updated | [ ] |
| LS-03 | `START.md` section B rewritten for LocalStack | [ ] |
| LS-04 | Close the follow-up in `terraform-infra.md` | [ ] |

## Acceptance criteria

- `bash scripts/test-localstack-init.sh` passes; `make verify` passes (or only fails on environmental tools also failing on 37f9545).
- `docker compose config -q` succeeds; no `rabbitmq` / `BROKER_` string remains in the compose.
- Live: `docker compose up -d localstack` becomes healthy only after the init script finished; `awslocal sns list-topics` shows 3 topics and `awslocal sqs list-queues` 6 queues.
- START.md section B has no RabbitMQ, management UI, lab-CA or AMQPS reference.

## Checks

`bash scripts/test-localstack-init.sh`, `make verify`, `docker compose -f docker-compose.yml config -q`, live LocalStack smoke.

## Progress / Next step

Status: LS-01 done. Next: LS-02 (compose rework).

## Evidence

### LS-01 evidence

- Route: delegated writer. TDD on, runner `bash scripts/test-localstack-init.sh`.
- RED: the test failed before the script existed: `FAIL: exit 127 (... localstack-init.sh: No such file or directory)` plus `FAIL: topic scan-requests not created` (and the same for every topic, queue, redrive and subscription assertion).
- GREEN: `test-localstack-init: OK` (3 topics, 6 queues, redrive `maxReceiveCount=3` on the 3 main queues only, 3 subscriptions with `RawMessageDelivery=true`, outcomes `FilterPolicy` only, requests visibility 970 = 10 + 900 + 60 and 30 for the others, custom timeouts honoured, second run issues the same commands, readiness marker written last and only on success). `shellcheck -x` clean.
- Design: ARNs are deterministic (account `000000000000`, region `us-east-1`), so the script only reads back the subscription ARN. Attributes are applied with `set-queue-attributes` (create-queue fails on an existing queue with different attributes). DLQs keep default attributes, as in terraform.
- Readiness: the script touches `/tmp/localstack-init.done` last (removed at start); the compose healthcheck (LS-02) checks it, so health means the topology exists.
