# Feature: terraform-infra

Master plan: `infra` : `odd/tasks/cloud-native-deploy.md` (Engram `odd/cloud-native-deploy/tasks`).
Engram topic for this doc: `odd/terraform-infra/tasks` (project: infra). Branch: `feature/compose_paths` (TF-01).

## Objective

Replace the imperative scripts in `deploy/aws/` with Terraform that creates the same shared
infrastructure plus the SNS + SQS messaging layer (replacing RabbitMQ, decision 2026-10-17), idempotently, with remote state.

## Scope

In: all shared AWS infra, ECS service shells, outputs, GitHub-secret refresh helper.
Out: service image builds and task-def revisions (service repos' CI), gateway redesign, RDS/DocumentDB.

## Constraints

- AWS Academy Learner Lab: reuse `LabRole` (data source), no IAM role creation; region `us-east-1`.
- Cloud Map namespace comes from ECS cluster `service_connect_defaults`.
- App ECS services use a bootstrap task def and `lifecycle { ignore_changes = [task_definition] }`.
- Spikes (master Phase 1) gate TF-03 (backend bucket) and TF-10 (messaging: broker MSG-01 sign-off and MSG-02 LabRole-from-ECS spike).
- All ECS tasks share `LabRole` (no `iam:CreateRole`): no per-service least privilege; SQS/SNS resource policies are the only isolation.
- No RabbitMQ ECR repo, ECS service or AMQP security-group rules.
- No secrets or state in git.
- No `aws_s3_bucket` can be managed by Terraform in this Learner Lab: an SCP explicitly denies `s3:GetBucketObjectLockConfiguration`, which the aws provider calls on every read. The state bucket is created by `scripts/bootstrap-state-bucket.sh` (AWS CLI).
- The lab denies `servicediscovery:CreateHttpNamespace` and `servicediscovery:GetNamespace`: the Cloud Map namespace is created by `scripts/bootstrap-namespace.sh` and its ARN enters Terraform as `var.namespace_arn`.

## Tooling

- TDD mode: `Strict (source: user global config)`
- Runner: `terraform fmt -check && terraform validate && terraform plan`; `actionlint` for workflows.
- Delivery: `ask-on-risk`, about 400 authored changed lines per PR slice.

## Checklist

| ID | Task | Replaces (in `deploy/aws/`) | Done |
|---|---|---|---|
| TF-01 | Fix compose build paths to `../<svc>` in `docker-compose.yml`; remove `REPO_ROOT` assumptions (`cd "$REPO_ROOT"` in `05`, `07`, `17`; definition in `00-env.sh`) | `00-env.sh`, `05`, `07`, `17` | [x] |
| TF-02 | Terraform skeleton: providers, `variables.tf` (region, project, `desired_count`), locals matching `00-env.sh` names | `00-env.sh` | [x] |
| TF-03 | S3 backend for remote state | `.state/*.txt` | [x] |
| TF-04 | Data sources: default VPC and subnets | `04-network.sh` (subnet_ids) | [x] |
| TF-05 | Security groups: ALB SG and internal SG with rules | `04-network.sh` | [x] |
| TF-06 | `data "aws_iam_role" "lab"` for `LabRole` | `03-iam-roles.sh` | [x] |
| TF-07 | ECR repos x4: user-service, nmap-service, gateway, front (`security-app/<name>`); no `rabbitmq` repo (RabbitMQ retired) | `02-ecr-repos.sh` | [x] |
| TF-08 | ALB, target groups, listeners; HTTPS via `tls_self_signed_cert` + `aws_acm_certificate` | `06-alb.sh`, `15-enable-https-gateway.sh` | [x] |
| TF-09 | ECS cluster with `service_connect_defaults` (namespace `security-app.local`, created beforehand by `scripts/bootstrap-namespace.sh`, ARN passed as `var.namespace_arn`) and CloudWatch log groups (`/ecs/security-app/*`) | `08-ecs-cluster-namespace-logs.sh` | [x] |
| TF-10 | Messaging: SNS topics (`scan-requests`, `scan-cancellations`, `scan-outcomes`), SQS queues + DLQs (redrive `maxReceiveCount=3`, `RedriveAllowPolicy`), SNS->SQS subscriptions (raw delivery, `FilterPolicy` on `routing_key`), queue policies (SNS source ARN, `aws:SecureTransport`) and SSE, as signed off in `broker` : `odd/tasks/sqs-sns-migration.md` (MSG-01, MSG-08). Replaces the `rabbitmq` ECS service. Planning heuristic about 400 changed lines; may span two slices | `10-deploy-tier0-infra.sh` (rabbitmq), `task-defs/rabbitmq.json` (both dropped) | [x] |
| TF-11 | postgres and mongo task defs via `templatefile()` from `task-defs/` JSON + ECS services with Service Connect aliases (`postgres:5432`, `mongo:27017`) | `09-register-task-defs.sh`, `10-deploy-tier0-infra.sh` | [x] |
| TF-12 | App services user-service, nmap-service, gateway, front: Service Connect config, bootstrap task def, `ignore_changes = [task_definition]`, ALB attachments for gateway/front | `11`, `12`, `13` | [x] |
| TF-13 | `desired_count` variable (0 = paused) | `20-pause.sh`, `21-resume.sh` | [x] |
| TF-14 | `refresh-gh-secrets.sh`: Learner Lab creds -> `gh secret set` on the service repos | new | [x] |
| TF-15 | Outputs: `alb_dns`, `gateway_public_url`, `front_public_url`, `scan_requests_topic_arn`, `scan_cancellations_topic_arn`, `scan_outcomes_topic_arn`, queue URLs | `.state/gateway_public_url.txt`, `14-verify.sh` | [x] |
| TF-16 | OAuth secrets for gateway delivered via SSM/Secrets Manager (spike 6) instead of `.state/google_oauth.env` | `16-update-gateway-oauth.sh` | [x] |
| TF-17 | Retire legacy `deploy/aws/` scripts after parity (keep `14-verify.sh` logic as a check) | all, `99-cleanup.sh` -> `terraform destroy` | [x] |

## Acceptance criteria

- `terraform apply` from empty reaches a working stack; a second `plan` shows no changes.
- Changing a service's task-def revision outside Terraform does not produce a plan diff.
- gateway `/health` OK, OpenAPI served, `/auth/login` returns 302, front returns 200.
- Scan flow works through SNS + SQS; a message that fails 3 times lands in its DLQ.
- No secrets or tfstate tracked in git.

## Checks

`terraform fmt -check`, `terraform validate`, `terraform plan`, `actionlint`, `shellcheck refresh-gh-secrets.sh`.

## Progress / Next step

Status: TF-01 and TF-02 done. 2026-10-17: TF-10 replaced (was `aws_mq_broker`, denied in the Learner Lab). TF-03 to TF-16 done (live plans verified 2026-10-18/19). 2026-10-19: TF-17 done (legacy `deploy/aws/` retired). TF-01..TF-17 done.

## TF-01 evidence

- Route: delegated writer (bounded), TDD Strict, runner `make verify` (`scripts/check-paths.sh` + `bash -n`; shellcheck not installed).
- RED: `make verify` exit 2 before the fix, 21 FAIL lines (compose contexts and bind mounts missing under `infra/`, `REPO_ROOT` still referenced, scripts without `SERVICES_ROOT`).
- GREEN: `make verify` prints `check-paths: OK` and `bash -n: OK`; `docker compose config --quiet` exit 0.
- Change: compose paths now `../<svc>`; `SERVICES_ROOT` (default: 3 levels above `00-env.sh`, env-overridable) replaces `REPO_ROOT`; docs paths fixed.
- Commit: 4d2c270.

- Native review (RDD): risk high, consent granted, 4 lenses (risk, resilience, readability, reliability), no blocking findings; approved and acknowledged 2026-10-17 (lineage `review-85e5427206d4516a`, authority burned). Reviewed boundary advances to `eece9a4`.
- Delivery: branch `feature/compose_paths` pushed to origin; merge into `develop` is the user's decision.

## TF-02 evidence

- Route: delegated writer (bounded), TDD Strict, runner `make verify` (adds `terraform fmt -check`, `init -backend=false`, `validate`, `test`, `tflint`).
- RED: `terraform test` failed on the first run (undeclared outputs and variables; 3 runs skipped) before any implementation.
- GREEN: `terraform test` 4 passed (names match `00-env.sh`, `desired_count` default 1, negative rejected via `expect_failures`, 0 accepted); `make verify` exit 0, no AWS credentials needed (`mock_provider "aws"`).
- Layout: `terraform/` with `versions.tf` (`~> 1.16.0`, aws `~> 6.0`), `providers.tf` (`default_tags`), `variables.tf`, `locals.tf`, `outputs.tf`, `.tflint.hcl` (terraform recommended + aws ruleset 0.40.0), committed `.terraform.lock.hcl` (linux_amd64, windows_amd64, darwin_arm64, darwin_amd64). Backend block marker left for TF-03.
- `.mise.toml` (terraform 1.16.6, tflint 0.64.0, shellcheck 0.11.0) committed in its own commit.
- Makefile: shellcheck now covers `scripts/*.sh` only; `deploy/aws/*.sh` has 24 pre-existing findings (3 warning, 21 note), left unfixed and out of `verify`.
- Commits: 8a8566d (mise), b71c2a5 (skeleton).

## TF-03 evidence (code done; live steps pending, task stays unchecked)

- Route: delegated writer (bounded), TDD Strict, runner `make verify`.
- RED: `scripts/check-backend.sh` failed (no `backend "s3" {}`, no `backend.hcl`); `terraform -chdir=terraform/bootstrap test` failed (module did not exist: unknown provider, 0 runs).
- GREEN: bootstrap `terraform test` 7 passed (name format, project override, force_destroy false, versioning Enabled, AES256, 4 public-access flags, SecureTransport deny); main root 4 passed; `make verify` exit 0, no credentials, no backend.
- Layout: bucket `<project>-tfstate-<account_id>` created by `scripts/bootstrap-state-bucket.sh` (superseded the Terraform bootstrap module, see below); main root `backend "s3" {}` partial + committed `terraform/backend.hcl` (key, region, `use_lockfile = true`, `encrypt = true`); `terraform/README.md`.
- Backend assertions: `scripts/check-backend.sh` (Terraform tests cannot inspect backend blocks), wired into `make verify`.
- Bucket name is passed with `-backend-config="bucket=$BUCKET"` (simplest; keeps the account ID out of git).
- Commit: 61d6be0.

### Change 2026-10-18: Terraform bootstrap replaced by an AWS CLI script

- Finding: the Terraform bootstrap apply created the bucket, but every later plan or refresh failed: "is not authorized to perform: s3:GetBucketObjectLockConfiguration ... with an explicit deny in a service control policy". The aws provider calls it on every read of `aws_s3_bucket`, so the module is unusable in this Learner Lab.
- Decision (user): delete `terraform/bootstrap/` and use `scripts/bootstrap-state-bucket.sh` (idempotent, AWS CLI: create-bucket if `head-bucket` fails, versioning, SSE AES256, public access block, TLS-only policy, read-back checks; `--dry-run`; no object-lock API; never deletes). Spike 5 showed these CLI calls work in the lab.
- Verified live (2026-10-18): `terraform init -backend-config=backend.hcl -backend-config="bucket=..."` against the bucket succeeded; `use_lockfile` locking works (a concurrent second plan failed with "Error acquiring the state lock").
- RED: `scripts/test-bootstrap-state-bucket.sh` failed on all assertions (script did not exist, exit 127). GREEN: test passes; `make verify` exit 0.
- Tests: `scripts/test-bootstrap-state-bucket.sh` (fake `aws` on PATH; bucket name, create only when missing, versioning/encryption/PAB/policy args, SecureTransport deny, no object-lock call, last stdout line, `--dry-run` has no mutating call), wired into `make verify`.
- Note: a `terraform/.terraform` left by a live backend init makes `make verify` try the S3 backend (`init -backend=false` is not enough); remove it or run verify in a clean checkout.

### Pending live steps (task stays unchecked until the script runs live)

```sh
export AWS_PROFILE=learnerlab
BUCKET="$(scripts/bootstrap-state-bucket.sh | tail -1)"   # live run pending
cd terraform && terraform init -backend-config=backend.hcl -backend-config="bucket=$BUCKET"
```

### TF-03 live run (2026-10-18)
- `scripts/bootstrap-state-bucket.sh` (AWS_PROFILE=learnerlab) re-applied settings on the existing bucket `security-app-tfstate-<account_id>` and verified versioning Enabled, SSE AES256, full public-access block and the TLS-only deny policy; a second run was idempotent.
- `terraform init -backend-config=backend.hcl -backend-config="bucket=$BUCKET"` succeeded; a concurrent `plan -lock-timeout=0s` failed with "Error acquiring the state lock" (native `use_lockfile` locking works); `terraform plan` through the backend shows output changes only.
- `make verify` now uses `TF_DATA_DIR=.terraform-verify` so a live backend init does not break offline verification (commit `3486051`).

## TF-04 evidence

- Route: delegated writer (bounded), TDD Strict, runner `make verify`. Branch `feature/network_data`.
- RED: `terraform test` failed on the new `tests/network.tftest.hcl` before any implementation (undeclared data sources and outputs; 1 failed, 1 skipped).
- GREEN: `make verify` exit 0; `terraform test` 6 passed (vpc_id equals mocked VPC; unsorted mocked subnets come out sorted; at least 2 subnets; 1 subnet rejected via `expect_failures = [output.subnet_ids]`).
- Change: `terraform/network.tf` (`data.aws_vpc.default`, `data.aws_subnets.default` filtered by `vpc-id` and `default-for-az`); `locals.vpc_id` and `locals.subnet_ids = sort(...)`; outputs `vpc_id`, `subnet_ids` (precondition: at least 2 subnets for the ALB). `skeleton.tftest.hcl` now mocks `aws_subnets` so its runs satisfy the precondition.
- Commit: 301458f (code and tests), doc commit follows.
- Live (2026-10-18): `terraform init -reconfigure` on the S3 backend, then a read-only `terraform plan -lock=false` with profile `learnerlab`. It resolved `vpc_id = vpc-0dc74a0e189367f3a` and 6 default subnets (sorted), with no resource changes (outputs only). Nothing was applied.

## TF-05 evidence

- Route: direct inline (one non-trivial file, `security_groups.tf`, plus its test). TDD Strict, runner `make verify`. Branch `feature/security_groups`.
- Pre-check (read-only): the default VPC held only the `default` SG, so there was nothing to import.
- RED: `terraform test` failed on the new `tests/security_groups.tftest.hcl` (resources undeclared; 1 failed, 2 skipped).
- GREEN: `make verify` exit 0; `terraform test` 9 passed.
- Change: `aws_security_group.alb` (ingress 80/443/8080 from 0.0.0.0/0; egress only TCP 8080 to the internal SG) and `aws_security_group.internal` (self ingress 5432/27017/8080; 8080 from the ALB SG; all egress). Uses the standalone `aws_vpc_security_group_*_rule` resources. Outputs `alb_sg_id`, `internal_sg_id`.
- Deviations from `04-network.sh`: the RabbitMQ ports 5672/5671/15672 were dropped (SNS/SQS replace RabbitMQ), and ALB egress was narrowed from all traffic to the tasks' container port.
- Test note: the SG tests use `command = apply` on the mocked provider, because `override_resource` ids stay unknown during `plan`.
- Live (2026-10-18): read-only `terraform plan -lock=false` showed `Plan: 11 to add, 0 to change, 0 to destroy`. Nothing was applied.
- Commit: 85c6891 (code, tests and this doc).
- Native review (RDD): risk high, consent granted, 4 lenses, 0 findings; approved and acknowledged 2026-10-18 (lineage `review-33d083b97de1e36b`, authority burned).

## TF-06 evidence

- Route: direct inline (one data source plus an output and a test). TDD Strict, runner `make verify`. Branch `feature/lab_role`.
- RED: `terraform test` failed on the new `tests/iam.tftest.hcl` (undeclared `data.aws_iam_role.lab`; 9 passed, 1 failed).
- GREEN: `make verify` exit 0; `terraform test` 10 passed.
- Change: `terraform/iam.tf` (`data "aws_iam_role" "lab"` by `local.lab_role_name`) and output `lab_role_arn`. No role is created.
- Live (2026-10-18): read-only `terraform plan -lock=false` resolved `lab_role_arn = arn:aws:iam::<account_id>:role/LabRole` (iam:GetRole is allowed); still `Plan: 11 to add` (the TF-05 SGs). Nothing was applied.
- Commit: 06ac77f (code, tests and this doc). Review assess: medium, `under_budget` (no review due).

## TF-07 evidence

- Route: direct inline (one resource file plus an output and a test). TDD Strict, runner `make verify`. Branch `feature/ecr_repos`.
- Pre-check (read-only): no ECR repositories existed in the account, so there was nothing to import.
- RED: `terraform test` failed on the new `tests/ecr.tftest.hcl` (undeclared resources; 10 passed, 1 failed, 2 skipped).
- GREEN: `make verify` exit 0; `terraform test` 13 passed.
- Change: `terraform/ecr.tf` with `aws_ecr_repository.app` for the 4 app services (scan on push, `MUTABLE`, `force_delete = true`) and `aws_ecr_lifecycle_policy.app` (expire untagged images after 7 days). Output `ecr_repository_urls`.
- Decisions: tags stay `MUTABLE` because `deploy/aws` still pushes `:latest` (revisit with the service CI, which pushes SHA tags). `force_delete` lets `terraform destroy` remove repos holding rebuildable images. The lifecycle policy is new: each `:latest` push leaves the previous image untagged.
- Live (2026-10-18): read-only `terraform plan -lock=false` showed `Plan: 19 to add` (11 SG resources plus 4 repos and 4 lifecycle policies). Nothing was applied.
- Commit: e18cf8b (code, tests and this doc). Review assess: medium, `under_budget` (no review due).

## TF-08 evidence

- Route: direct inline (one resource file `alb.tf`, its test, shared mocks, outputs, provider pin). TDD Strict, runner `make verify`. Branch `feature/alb_https`.
- RED: `terraform test` failed on the new `tests/alb.tftest.hcl` (undeclared resources; 13 passed, 1 failed, 4 skipped).
- GREEN: `make verify` exit 0; `terraform test` 18 passed.
- Change: `terraform/alb.tf` with `aws_lb.main` (internet-facing, default subnets, ALB SG, `drop_invalid_header_fields`), `aws_lb_target_group.app` for front (`/`) and gateway (`/health`) on 8080 by IP with the `06-alb.sh` health timings, `tls_private_key` + `tls_self_signed_cert` (CN and SAN = ALB DNS, 365 days, renewed by a plan within 30 days of expiry), `aws_acm_certificate.alb` (`create_before_destroy`), and listeners 80 -> 301 to HTTPS 443, 443 HTTPS -> front, 8080 HTTPS -> gateway (policy `ELBSecurityPolicy-TLS13-1-2-2021-06`). Outputs `alb_dns`, `front_public_url`, `gateway_public_url`.
- Provider: `hashicorp/tls ~> 4.0` (locked 4.4.1 for the 4 platforms; aws lock unchanged).
- Tests: `tests/mocks/aws.tfmock.hcl` gives `aws_lb`, `aws_lb_target_group` and `aws_acm_certificate` valid ARN defaults, because the provider validates ARN shapes on mocked `apply`; every test file now uses `mock_provider "aws" { source = "./tests/mocks" }`.
- Deviation from the scripts: Terraform goes straight to the HTTPS end state (the HTTP-only listeners of `06-alb.sh` are not recreated). The certificate private key moves from `.state/gateway-cert/` to the encrypted S3 state.
- Live (2026-10-18): read-only `terraform plan -lock=false` showed `Plan: 28 to add` (19 earlier plus the ALB, 2 TGs, 3 listeners, key, certificate and ACM import). Nothing was applied.
- Commit: df9514c (code, tests and this doc).
- Native review (RDD): risk high, consent granted, 4 lenses, 0 findings; approved and acknowledged 2026-10-18 (lineage `review-dd69d20be332141c`, authority burned).

## TF-09 evidence

- Route: delegated writer (bounded), TDD Strict, runner `make verify`. Branch `feature/ecs_cluster`.
- RED: `terraform test` failed on the new `tests/ecs.tftest.hcl` (undeclared data source and resources; 18 passed, 1 failed, 3 skipped).
- GREEN: `make verify` exit 0; `terraform test` 22 passed; shellcheck clean on `scripts/*.sh`; `scripts/test-bootstrap-namespace.sh` OK (RED: script missing, all assertions failed).
- Change: `terraform/ecs.tf` with `data.aws_service_discovery_http_namespace.main` (by name), `aws_ecs_cluster.main` (`security-app-cluster-v2`, `service_connect_defaults` = namespace ARN), `aws_ecs_cluster_capacity_providers.main` (FARGATE, default strategy weight 1) and `aws_cloudwatch_log_group.service` for the 6 task-family services (`/ecs/security-app/<svc>`, 3 days, no rabbitmq). Outputs `cluster_arn`, `namespace_arn`, `log_group_names`.
- Script: `scripts/bootstrap-namespace.sh` (idempotent; if the namespace is not listed, creates a throwaway cluster `<project>-ns-bootstrap` with `--service-connect-defaults namespace=<project>.local`, retries the service-linked-role error, polls `list-namespaces` 20 x 3 s, always deletes the throwaway cluster via trap, never deletes the namespace; `--dry-run`; last stdout line is the namespace ARN). Tested offline by `scripts/test-bootstrap-namespace.sh` (fake `aws`), wired into `make verify`.
- Tests: shared mocks gain `mock_data "aws_service_discovery_http_namespace"` (valid ARN) because the provider validates the ARN on mocked apply; `skeleton.tftest.hcl` now uses the shared mocks source.
- Decision: namespace via CLI, not Terraform, because `voclabs` is denied `servicediscovery:CreateHttpNamespace` (verified live 2026-10-18, AccessDeniedException) and the provider (6.69.1) requires an ARN, not a name, for `service_connect_defaults.namespace`. Only the namespace lives outside Terraform, like the state bucket.
- Commit: 3d5ad7c. Native review (RDD): risk high, granted, 4 lenses, 0 findings, approved (lineage `review-0fe0ca9f1f8d716a`, burned).
- Live (2026-10-18, user-approved): `scripts/bootstrap-namespace.sh` created `security-app.local` (`ns-t3qf4rogyv6mtkcz`) through the throwaway cluster, which ended `INACTIVE` (deleted); a second run printed "nothing to do" (idempotent).
- Live finding: the read-only `terraform plan` failed in the data source with `AccessDeniedException ... servicediscovery:GetNamespace` (the lab allows `ListNamespaces` but not `GetNamespace`).
- Correction: the data source was replaced by the required variable `namespace_arn` (validated as a Cloud Map namespace ARN), fed with `export TF_VAR_namespace_arn="$(scripts/bootstrap-namespace.sh | tail -1)"`. The shared `mock_data` was removed; every test file sets `namespace_arn` in a `variables` block; `ecs.tftest.hcl` adds an invalid-ARN `expect_failures` run. RED: 0 passed, 7 failed (invalid mocked ARN, variable undeclared). GREEN: `make verify` exit 0, `terraform test` 23 passed.
- Live plan after the correction: `Plan: 36 to add, 0 to change, 0 to destroy` with `namespace_arn` resolved. Nothing was applied.
- Open risk: `ecs:CreateCluster` with an existing namespace ARN might need extra `servicediscovery` permissions for the caller; only the first `apply` can prove it.

## TF-10 evidence

- Route: direct inline (one resource file `messaging.tf`, its test, mocks, variables, outputs). TDD Strict, runner `make verify`. Branch `feature/messaging`.
- Contract: broker `odd/tasks/sqs-sns-migration.md`, MSG-01 table and Q1-Q8 (signed off 2026-10-17).
- RED: `terraform test` failed on the new `tests/messaging.tftest.hcl` (undeclared resources; 23 passed, 1 failed, 6 skipped).
- GREEN: `make verify` exit 0; `terraform test` 30 passed.
- Change: SNS topics `scan-requests`, `scan-cancellations`, `scan-outcomes` with a topic policy (account access, deny non-TLS). SQS queues `ms-nmap-scan-requests`, `ms-nmap-scan-cancellations`, `gateway-scan-outcomes`, each with a `<name>-dlq`: standard, SSE-SQS, long polling 20 s, `maxReceiveCount = 3`, `RedriveAllowPolicy` byQueue (separate resource to avoid a cycle). Queue policies allow `sqs:SendMessage` only from `sns.amazonaws.com` with `aws:SourceArn` = the subscribed topic, and deny non-TLS; DLQ policies only deny non-TLS. Raw-delivery subscriptions; the gateway filter is `{"routing_key":[{"prefix":"scan.outcome."}]}`. `ms-analisis` queues deferred (Q7).
- Timeouts and retention: requests visibility = `ssh_connect_timeout_secs` (10) + `ssh_command_timeout_secs` (900) + 60 = 970 s (Q1; new variables, defaults from `task-defs/nmap-service.json`, validated against the 12 h SQS limit); requests retention 1 h and its DLQ 24 h (Q4); other queues 4 days and DLQs 14 days; cancellations and outcomes visibility 30 s.
- Outputs: `sns_topic_arns`, `sqs_queue_urls`, `sqs_dlq_urls` (maps by name).
- Not done: SNS server-side encryption (needs KMS; Q4 chose SSE-SQS only).
- Commit: 5fa5b7a. Review: medium, `under_budget`; offered under the user policy (TF-10 is security-relevant) and declined by the user.
- Live (2026-10-19): the first plan failed with `ExpiredToken`; after a credential refresh, the read-only `terraform plan -lock=false` showed `Plan: 60 to add` (24 messaging resources: 3 topics, 3 topic policies, 6 queues, 6 queue policies, 3 redrive-allow policies, 3 subscriptions) and `data.aws_caller_identity` resolved. Nothing was applied.

## TF-11 evidence

- Route: direct inline (one resource file `data_services.tf`, its test, mocks, provider pin). TDD Strict, runner `make verify`. Branch `feature/data_services`.
- Decision (user, 2026-10-19): the hardcoded `POSTGRES_PASSWORD=devpassword` is replaced by `random_password.postgres` (32 chars, no special characters so it is URL-safe) stored in the SSM SecureString `/security-app/postgres/password` and injected through the container `secrets`. The value also lives in the encrypted S3 state.
- RED: `terraform test` failed on the new `tests/data_services.tftest.hcl` (undeclared resources; 30 passed, 1 failed, 4 skipped).
- GREEN: `make verify` exit 0; `terraform test` 35 passed.
- Change: `aws_ecs_task_definition.data` and `aws_ecs_service.data` for postgres and mongo (Fargate awsvpc 256/512, LabRole execution role, public ECR mirror images, legacy health checks, awslogs to the TF-09 log groups; services in the internal SG with a public IP, Service Connect aliases `postgres:5432` and `mongo:27017`, `desired_count = var.desired_count`).
- Deviation: container definitions are built with `jsonencode` in HCL instead of `templatefile()` over `task-defs/*.json`; the JSON files stay until TF-17.
- Provider: `hashicorp/random ~> 3.0` (locked 3.9.1 for the 4 platforms). Shared mocks gained `aws_ecs_cluster`, `aws_ecs_task_definition`, `aws_ssm_parameter` and `data.aws_iam_role` ARN defaults.
- Follow-up for TF-12: `task-defs/user-service.json` still uses `devpassword`; user-service must read `/security-app/postgres/password`.
- Live (2026-10-19): read-only `terraform plan -lock=false` showed `Plan: 66 to add` (60 earlier plus 2 task definitions, 2 services, the SSM parameter and the random password). Nothing was applied.

## TF-12 evidence

- Route: delegated writer (bounded), TDD Strict, runner `make verify`. Branch `feature/app_services`.
- RED: `terraform test` failed on the new `tests/app_services.tftest.hcl` (undeclared resources; 35 passed, 1 failed, 9 skipped).
- GREEN: `make verify` exit 0; `terraform test` 45 passed.
- Change: `terraform/app_services.tf` with `aws_ecs_task_definition.app` and `aws_ecs_service.app` (`for_each` over `local.app_services`) for user-service, nmap-service, gateway and front. Fargate awsvpc 256/512; LabRole as execution and task role (tasks call SQS/SNS/SSM); images `<ECR repository_url>:latest`; awslogs to the TF-09 log groups; services in the internal SG with a public IP and `desired_count = var.desired_count`.
- Ownership (decision): Terraform registers a complete bootstrap task definition so the stack runs before CI exists; each service has `lifecycle { ignore_changes = [task_definition] }` because the service repos' CI owns later revisions. The CI task definitions must reference the same SSM parameter names as below.
- Service Connect: user-service publishes `user-service:8080`; nmap-service and gateway are client-only; front has none (as in script 13). gateway and front attach to `aws_lb_target_group.app[...]` (container port 8080, `health_check_grace_period_seconds = 60`); all services `depends_on` both HTTPS listeners (`depends_on` cannot be conditional).
- Secrets (same pattern as TF-11): `random_password` / `random_id` stored in SSM SecureStrings and injected via container `secrets`, never plain `environment`: `/security-app/gateway-shared-secret` (user-service `GATEWAY_SHARED_SECRET` and gateway `MS_USUARIOS_SHARED_SECRET`), `/security-app/user-service/credentials-encryption-key` (32 bytes as 64 hex chars), `/security-app/gateway/session-signing-key`, `/security-app/user-service/database-url` (embeds `random_password.postgres`; closes the TF-11 follow-up). The values also live in the encrypted S3 state. Google OAuth stays `dev-placeholder` plain env until TF-16.
- Messaging env: RabbitMQ variables dropped (`BROKER_*`, `MS_NMAP_BROKER_*`, `SSL_CERT_FILE`). gateway gets `AWS_REGION`, `SCAN_REQUESTS_TOPIC_ARN`, `SCAN_CANCELLATIONS_TOPIC_ARN`, `GATEWAY_SCAN_OUTCOMES_QUEUE_URL`, `GATEWAY_SCAN_OUTCOMES_DLQ_URL`; nmap-service gets `AWS_REGION`, `MS_NMAP_SCAN_REQUESTS_QUEUE_URL`, `MS_NMAP_SCAN_CANCELLATIONS_QUEUE_URL`, `MS_NMAP_SCAN_OUTCOMES_TOPIC_ARN` and the two `*_DLQ_URL`. The gateway/nmap code still speaks AMQP until MSG-GW/MSG-NM land, so these two start but will not process scans yet. nmap SSH timeouts come from `ssh_connect_timeout_secs` / `ssh_command_timeout_secs`.
- Deviation: container definitions are built with `jsonencode` in HCL; the `task-defs/*.json` files stay until TF-17.
- Live (2026-10-19): parent re-ran `make verify` (exit 0, 45 passed) and a read-only `terraform plan -lock=false`: `Plan: 81 to add` (66 earlier plus 4 task definitions, 4 services, 4 SSM parameters and 3 random values). Nothing was applied.
- Commit: 5115cb5. Review: medium, `slice_budget_reached`; declined under the user policy (only TF-10/14/16 are offered).

## TF-13 evidence

- Route: direct inline (one test file, one `depends_on` line, a README section). TDD Strict, runner `make verify`. Branch `feature/pause_resume`.
- Finding: the behavior already existed. TF-11 and TF-12 wired `var.desired_count` (validated `>= 0`, default 1) into all six services and each had its own pause test. So there was no RED for the behavior; `tests/pause.tftest.hcl` is a regression check that one variable pauses and resumes all six services and the `desired_count` output.
- Change: app services now also `depends_on` the data services, so Terraform updates postgres and mongo before their clients (the tier order of `21-resume.sh`). README gains "Pause and resume" (`terraform apply -var desired_count=0` / `terraform apply`; databases start empty; ALB, SQS, SNS and SSM stay up). No `wait_for_steady_state`: gateway and nmap-service cannot become healthy until MSG-GW/MSG-NM land, so a wait would hang the apply.
- GREEN: `make verify` exit 0; `terraform test` 47 passed.
- Live (2026-10-19): read-only `terraform plan -lock=false -var desired_count=0` showed all six services with `desired_count = 0` (`Plan: 81 to add`). Nothing was applied.

## TF-14 evidence

- Route: direct inline (one script plus its offline test, Makefile wiring, README). TDD Strict, runner `make verify`. Branch `feature/gh_secrets`.
- RED: `scripts/test-refresh-gh-secrets.sh` failed on every case (script missing, exit 127).
- GREEN: `make verify` exit 0 (`test-refresh-gh-secrets: OK`, shellcheck clean, `terraform test` 47 passed).
- Change: `scripts/refresh-gh-secrets.sh` reads the `learnerlab` profile, validates it with `sts get-caller-identity` before any write (an expired session aborts and asks for a refresh), requires a session token (refuses non-lab credentials), requires `gh auth status`, then sets secrets `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN` and variable `AWS_REGION` on the 4 service repos. Values go to `gh` on stdin (never argv) and are never printed. `--dry-run`; overrides `AWS_PROFILE`, `AWS_REGION`, `GH_OWNER`, `REPOS`.
- Tests (fake `aws` and `gh`): happy path (12 secrets + 4 variables, values only on stdin, nothing printed), expired credentials, missing session token, unauthenticated gh, overrides, dry run.
- Not included: the `infra` repo itself (no Terraform CI yet).
- Commit: d463b7a. Review: high; offered under the user policy (TF-14) and declined by the user.
- Live (2026-10-19, user-authorized gh session and learnerlab profile): `--dry-run` validated the credentials and gh auth and listed the 4 repos; the real run updated all 4. `gh secret list` / `gh variable list` show `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN` and `AWS_REGION` on each repo. No value was printed.

## TF-15 evidence

- Route: direct inline (outputs plus one test file). TDD Strict, runner `make verify`. Branch `feature/outputs`.
- Already exported by earlier tasks: `alb_dns`, `front_public_url`, `gateway_public_url` (TF-08), `sns_topic_arns`, `sqs_queue_urls`, `sqs_dlq_urls` (TF-10).
- RED: `terraform test` failed on the new `tests/outputs.tftest.hcl` (undeclared outputs; 47 passed, 1 failed, 2 skipped).
- Change: outputs `scan_requests_topic_arn`, `scan_cancellations_topic_arn`, `scan_outcomes_topic_arn` and `service_names` (sorted list of the six ECS services, for the `describe-services` check that replaces `14-verify.sh` in TF-17).
- GREEN: `make verify` exit 0; `terraform test` 50 passed (one fix in the test itself: list vs tuple comparison needed `tolist`).
- Live (2026-10-19): read-only `terraform plan -lock=false` lists the new outputs (`Plan: 81 to add`, no new resources). Nothing was applied.

## TF-16 evidence

- Route: direct inline (Terraform change, one script plus its offline test, README). TDD Strict, runner `make verify`. Branch `feature/oauth_ssm`.
- Decision (user, 2026-10-19, option A): the real Google OAuth client never passes through Terraform. Terraform seeds `aws_ssm_parameter.google_oauth` (`/security-app/gateway/google-client-id`, `/security-app/gateway/google-client-secret`, SecureString) with the placeholder `unset-run-scripts-set-google-oauth` and `ignore_changes = [value]`; `scripts/set-google-oauth.sh` writes the real values.
- RED: `terraform test` 48 passed, 3 failed (gateway secrets map, env map and the new `google_oauth_lives_only_in_ssm` run); `scripts/test-set-google-oauth.sh` failed (script missing, exit 127).
- GREEN: `make verify` exit 0; `terraform test` 51 passed; `test-set-google-oauth: OK`; shellcheck clean.
- Change: gateway task definition reads `GOOGLE_CLIENT_ID` and `GOOGLE_CLIENT_SECRET` from SSM through `secrets`; the `dev-placeholder` env values are gone. The script takes the values from the environment or the legacy `deploy/aws/.state/google_oauth.env`, validates the `learnerlab` credentials with STS first, puts both parameters through 0600 temp files (`--value file://`, never argv), never prints them, deletes the temp files, then runs `ecs update-service --force-new-deployment` on the gateway. `--dry-run` writes nothing.
- Replaces `16-update-gateway-oauth.sh` (no more task-definition re-registration with secrets inline).
- Live (2026-10-19): read-only `terraform plan -lock=false` showed the two parameters (`Plan: 83 to add`). Nothing was applied. A live run of the script needs the applied stack (the gateway service must exist).
- Commit: 2cb6f2d. Native review (RDD): risk high, offered under the user policy (TF-16) and granted; 4 lenses, 0 findings; approved and acknowledged 2026-10-19 (lineage `review-7bc036da1a158c68`, burned).

## TF-17 evidence (part 1)

- Route: delegated writer (two scripts, two offline tests, Makefile wiring, README). TDD Strict, runner `make verify`. Branch `feature/stack_tools`.
- User-approved split: part 1 adds `scripts/push-images.sh` and `scripts/verify-stack.sh`. Part 2 deletes `deploy/aws/` and updates `START.md` and `deploy/aws/CONSOLE_GUIDE.md`, only after a real `terraform apply` plus a passing `verify-stack.sh`. TF-17 stays unticked.
- RED: `scripts/test-push-images.sh` failed 35 checks (script missing, exit 127); `scripts/test-verify-stack.sh` failed 29 checks (script missing).
- GREEN: both tests print `OK`; shellcheck clean; see the `make verify` result below.
- Change: `push-images.sh` (replaces 05, 07, 17) reads `ecr_repository_urls`, `gateway_public_url`, `cluster_name` from `terraform output -json`, validates credentials with STS, logs in to ECR with the password on stdin only, builds and pushes `:latest` for all four services or a subset, passes `VITE_GATEWAY_BASE_URL` to front and the `tls` build context to nmap-service only if `broker/rabbitmq/tls` exists (drop with MSG-NM), then forces an ECS redeploy (`--no-redeploy` skips; `--dry-run` runs no docker or mutation). `verify-stack.sh` (replaces 14-verify.sh) checks gateway `/health` 200, `/api/openapi.json` 200, `/auth/login` 302, front `/` 200 (`curl -sk`, self-signed ALB certificate) and every service from `service_names` (ACTIVE, running == desired), printing `[OK]`/`[FAIL]` lines and exiting 1 on any failure. README gains "End-to-end deploy".
- Live: pending (needs the first apply).
- Commit: 4e313fa. Parent re-ran `make verify` (exit 0, 51 passed, all 6 script tests OK). Review: high; declined under the user policy (only TF-10/14/16 are offered).

## First live apply (2026-10-19)

- Authorized by the user. The classifier blocked the agent's `terraform apply`, so the user ran it in their own terminal (plan saved with `-out`, then applied).
- Result: 80 of 83 resources created (state lists 84 entries with the 4 data sources). The 3 `aws_sns_topic_policy.scan` failed: `SetTopicAttributes ... InvalidParameter: Policy statement action out of service scope!`.
- Cause: the deny-non-TLS statement used `Action = "sns:*"`; a topic policy only accepts the explicit SNS topic actions. The mocked tests could not see it.
- Fix (TDD): new run `topic_policies_only_use_actions_sns_accepts` in `tests/messaging.tftest.hcl` (RED: 51 passed, 1 failed on the `sns:*` action), then `local.sns_topic_actions` (Publish, Subscribe, Receive, GetTopicAttributes, SetTopicAttributes, AddPermission, RemovePermission, DeleteTopic, ListSubscriptionsByTopic) used in the deny statement. GREEN: `make verify` exit 0, 52 passed.
- Live plan after the fix: `Plan: 3 to add, 0 to change, 0 to destroy` (only the 3 topic policies). The user ran the second apply; the next plan reports `No changes` (83 resources, state matches the configuration).
- `scripts/push-images.sh` (agent, user-authorized): built and pushed the 4 images to ECR with `:latest` and forced a redeploy (exit 0).
- `scripts/verify-stack.sh`: 5 passed, 5 failed. OK: front HTTPS 200, ECS postgres, mongo, user-service and front 1/1. FAIL: gateway `/health`, `/api/openapi.json`, `/auth/login` and ECS gateway and nmap-service 0/1. Cause (from the logs, expected): the gateway and nmap-service code still needs the RabbitMQ configuration (`falta la variable de entorno requerida: MS_NMAP_BROKER_ENDPOINT`; gateway `no se pudo cargar la configuración`); they start once MSG-GW / MSG-NM land. A first gateway probe timed out (`000`) while the ALB was still settling; a direct probe then returned `503` (no healthy target), as expected. HTTP :80 redirects 301 to HTTPS :443.
- Fix: the verify-stack hint used `aws logs tail`, which aws-cli v1 lacks; it now suggests `aws logs filter-log-events` (test updated).

## TF-17 part 2 decision (user, 2026-10-19)

- Keep `deploy/aws/` until the gateway and nmap-service code speaks SNS/SQS (gateway `odd/tasks/sqs-sns-adapter.md` MSG-GW, nmap-service MSG-NM). Today the legacy scripts are the only way to run the whole app (with RabbitMQ).
- Close TF-17 when `scripts/verify-stack.sh` passes every check against the Terraform stack; then delete `deploy/aws/` and update `START.md` and `deploy/aws/CONSOLE_GUIDE.md`.
- Do not run the legacy scripts and the Terraform stack at the same time: they use the same resource names.

## TF-17 evidence (part 2)

- Route: delegated writer (offline only; no AWS, apply or docker). Branch `feature/retire_legacy_scripts`. Supersedes the "keep until MSG-GW/MSG-NM" decision above: the gateway and nmap-service moved to SNS/SQS, so the condition was met.
- Removed: 31 tracked files under `deploy/aws/` via `git rm` (scripts 00-21, 99, `create-test-target-ec2.sh`, `task-defs/*.json`, `README.md`, `CONSOLE_GUIDE.md`). The untracked `deploy/aws/.state/` (local secrets) was kept and stays gitignored.
- References updated: Makefile (dropped `bash -n deploy/aws/*.sh`), `scripts/check-paths.sh` (compose checks kept; legacy script checks replaced by `push-images.sh` SERVICES_ROOT checks), comments in `push-images.sh`, `verify-stack.sh`, `set-google-oauth.sh`, `docker-compose.yml`, `terraform/*.tf`, `terraform/tests`, `terraform/README.md`. `START.md` now opens with the Terraform flow and the one-time Google OAuth console steps; the docker compose guide is kept as section B.
- `make verify`: exit 0 (check-paths OK, all script tests OK, `bash -n` OK, terraform tests 52 passed).
- Live evidence: `scripts/verify-stack.sh` 10/10 on 2026-10-19 after `scripts/push-images.sh gateway nmap-service` and a resume apply.
- Follow-ups: (1) rework `docker-compose.yml` for LocalStack (SNS/SQS) instead of RabbitMQ; START.md section B still describes RabbitMQ. (2) Decide the rustls provider guard. (3) Optional `stopTimeout >= 30s` on the ECS task definitions. (4) A few test messages still cite legacy script names (`00-env.sh`, `06-alb.sh`) as history.

## Scan test target (2026-10-20)

- Route: delegated writer (offline only; fake `aws` on PATH, no real AWS call). Branch `feature/test_target`. Ports the deleted `deploy/aws/create-test-target-ec2.sh` to `scripts/create-test-target.sh` (+ `scripts/test-create-test-target.sh`, wired into `make verify`; docs in `terraform/README.md` and `START.md`).
- RED: the test run before the script existed failed (exit 127 for the missing script plus the create-path assertions).
- GREEN: `bash scripts/test-create-test-target.sh` prints `OK` after implementing; see the verification results of the parent run.
- Behavior: create-or-reuse (running instance reused without resetting the password, stopped one started), `--destroy` (terminate, wait terminated, delete SG), `--dry-run`; STS precheck; every aws call carries `--profile` and `--region`; nothing stored under `deploy/aws/.state`.
- Security change vs the legacy script: SSH ingress is `tcp/22` with `--source-group` of `${PROJECT}-internal-sg` (looked up by name; fails with "apply the Terraform stack first" if missing) instead of `0.0.0.0/0`. Scans use the private IP from the nmap-service tasks in the same VPC, so no public ingress is needed.

## Weak-config target (2026-10-21)

- Route: delegated writer (offline only; fake `aws` on PATH, no real AWS call). Branch `feature/weak_config_target` (off `feature/test_target`). Adds `scripts/create-weak-target.sh` + `scripts/test-create-weak-target.sh`, wired into `make verify`; docs in `terraform/README.md`.
- RED: the test run before the script existed failed (exit 127 plus all create-path assertions).
- GREEN: `bash scripts/test-create-weak-target.sh` prints `OK` after implementing.
- Misconfigurations (stock packages, insecure settings only): (1) nginx HTTPS on 8443 with a 1024-bit DH group (`ssl_dhparam`) and HTTP on 80 exposing `/.git/` with `autoindex on`; (2) vsftpd with `anonymous_enable=YES`, `local_enable=NO`, `write_enable=NO`, passive off; (3) SSH password login as in the test target. SG `${PROJECT}-weak-target-sg` opens tcp 22, 21, 80, 8443 only from `${PROJECT}-internal-sg`.
- Scan expectations: nmap-service MCF-01 surfaces http-git / http-trace / cookie-flags, and ssl-dh-params reports State VULNERABLE. ftp-anon needs the scan to also request that script (cross-repo follow-up in nmap-service).
