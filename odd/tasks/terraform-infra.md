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
| TF-06 | `data "aws_iam_role" "lab"` for `LabRole` | `03-iam-roles.sh` | [ ] |
| TF-07 | ECR repos x4: user-service, nmap-service, gateway, front (`security-app/<name>`); no `rabbitmq` repo (RabbitMQ retired) | `02-ecr-repos.sh` | [ ] |
| TF-08 | ALB, target groups, listeners; HTTPS via `tls_self_signed_cert` + `aws_acm_certificate` | `06-alb.sh`, `15-enable-https-gateway.sh` | [ ] |
| TF-09 | ECS cluster with `service_connect_defaults` (namespace `security-app.local`) and CloudWatch log groups (`/ecs/security-app/*`) | `08-ecs-cluster-namespace-logs.sh` | [ ] |
| TF-10 | Messaging: SNS topics (`scan-requests`, `scan-cancellations`, `scan-outcomes`), SQS queues + DLQs (redrive `maxReceiveCount=3`, `RedriveAllowPolicy`), SNS->SQS subscriptions (raw delivery, `FilterPolicy` on `routing_key`), queue policies (SNS source ARN, `aws:SecureTransport`) and SSE, as signed off in `broker` : `odd/tasks/sqs-sns-migration.md` (MSG-01, MSG-08). Replaces the `rabbitmq` ECS service. Planning heuristic about 400 changed lines; may span two slices | `10-deploy-tier0-infra.sh` (rabbitmq), `task-defs/rabbitmq.json` (both dropped) | [ ] |
| TF-11 | postgres and mongo task defs via `templatefile()` from `task-defs/` JSON + ECS services with Service Connect aliases (`postgres:5432`, `mongo:27017`) | `09-register-task-defs.sh`, `10-deploy-tier0-infra.sh` | [ ] |
| TF-12 | App services user-service, nmap-service, gateway, front: Service Connect config, bootstrap task def, `ignore_changes = [task_definition]`, ALB attachments for gateway/front | `11`, `12`, `13` | [ ] |
| TF-13 | `desired_count` variable (0 = paused) | `20-pause.sh`, `21-resume.sh` | [ ] |
| TF-14 | `refresh-gh-secrets.sh`: Learner Lab creds -> `gh secret set` on the service repos | new | [ ] |
| TF-15 | Outputs: `alb_dns`, `gateway_public_url`, `front_public_url`, `scan_requests_topic_arn`, `scan_cancellations_topic_arn`, `scan_outcomes_topic_arn`, queue URLs | `.state/gateway_public_url.txt`, `14-verify.sh` | [ ] |
| TF-16 | OAuth secrets for gateway delivered via SSM/Secrets Manager (spike 6) instead of `.state/google_oauth.env` | `16-update-gateway-oauth.sh` | [ ] |
| TF-17 | Retire legacy `deploy/aws/` scripts after parity (keep `14-verify.sh` logic as a check) | all, `99-cleanup.sh` -> `terraform destroy` | [ ] |

## Acceptance criteria

- `terraform apply` from empty reaches a working stack; a second `plan` shows no changes.
- Changing a service's task-def revision outside Terraform does not produce a plan diff.
- gateway `/health` OK, OpenAPI served, `/auth/login` returns 302, front returns 200.
- Scan flow works through SNS + SQS; a message that fails 3 times lands in its DLQ.
- No secrets or tfstate tracked in git.

## Checks

`terraform fmt -check`, `terraform validate`, `terraform plan`, `actionlint`, `shellcheck refresh-gh-secrets.sh`.

## Progress / Next step

Status: TF-01 and TF-02 done. 2026-10-17: TF-10 replaced (was `aws_mq_broker`, denied in the Learner Lab). TF-03, TF-04 and TF-05 done (live plans verified 2026-10-18). Next: TF-06.

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
