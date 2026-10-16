# Feature: terraform-infra

Master plan: `infra` : `odd/tasks/cloud-native-deploy.md` (Engram `odd/cloud-native-deploy/tasks`).
Engram topic for this doc: `odd/terraform-infra/tasks` (project: infra). Branch: `v1`.

## Objective

Replace the imperative scripts in `deploy/aws/` with Terraform that creates the same shared
infrastructure plus Amazon MQ for RabbitMQ, idempotently, with remote state.

## Scope

In: all shared AWS infra, ECS service shells, outputs, GitHub-secret refresh helper.
Out: service image builds and task-def revisions (service repos' CI), gateway redesign, RDS/DocumentDB.

## Constraints

- AWS Academy Learner Lab: reuse `LabRole` (data source), no IAM role creation; region `us-east-1`.
- Cloud Map namespace comes from ECS cluster `service_connect_defaults`.
- App ECS services use a bootstrap task def and `lifecycle { ignore_changes = [task_definition] }`.
- Spikes (master Phase 1) gate TF-03 (backend bucket) and TF-10 (MQ).
- No secrets or state in git.

## Tooling

- TDD mode: `Strict (source: user global config)`
- Runner: `terraform fmt -check && terraform validate && terraform plan`; `actionlint` for workflows.
- Delivery: `ask-on-risk`, about 400 authored changed lines per PR slice.

## Checklist

| ID | Task | Replaces (in `deploy/aws/`) | Done |
|---|---|---|---|
| TF-01 | Fix compose build paths to `../<svc>` in `docker-compose.yml`; remove `REPO_ROOT` assumptions (`cd "$REPO_ROOT"` in `05`, `07`, `17`; definition in `00-env.sh`) | `00-env.sh`, `05`, `07`, `17` | [ ] |
| TF-02 | Terraform skeleton: providers, `variables.tf` (region, project, `desired_count`), locals matching `00-env.sh` names | `00-env.sh` | [ ] |
| TF-03 | S3 backend for remote state | `.state/*.txt` | [ ] |
| TF-04 | Data sources: default VPC and subnets | `04-network.sh` (subnet_ids) | [ ] |
| TF-05 | Security groups: ALB SG and internal SG with rules | `04-network.sh` | [ ] |
| TF-06 | `data "aws_iam_role" "lab"` for `LabRole` | `03-iam-roles.sh` | [ ] |
| TF-07 | ECR repos x4: user-service, nmap-service, gateway, front (`security-app/<name>`); `rabbitmq-custom` retired | `02-ecr-repos.sh` | [ ] |
| TF-08 | ALB, target groups, listeners; HTTPS via `tls_self_signed_cert` + `aws_acm_certificate` | `06-alb.sh`, `15-enable-https-gateway.sh` | [ ] |
| TF-09 | ECS cluster with `service_connect_defaults` (namespace `security-app.local`) and CloudWatch log groups (`/ecs/security-app/*`) | `08-ecs-cluster-namespace-logs.sh` | [ ] |
| TF-10 | `aws_mq_broker` (RabbitMQ), replaces the `rabbitmq` ECS service | `10-deploy-tier0-infra.sh` (rabbitmq), `task-defs/rabbitmq.json` | [ ] |
| TF-11 | postgres and mongo task defs via `templatefile()` from `task-defs/` JSON + ECS services with Service Connect aliases (`postgres:5432`, `mongo:27017`) | `09-register-task-defs.sh`, `10-deploy-tier0-infra.sh` | [ ] |
| TF-12 | App services user-service, nmap-service, gateway, front: Service Connect config, bootstrap task def, `ignore_changes = [task_definition]`, ALB attachments for gateway/front | `11`, `12`, `13` | [ ] |
| TF-13 | `desired_count` variable (0 = paused) | `20-pause.sh`, `21-resume.sh` | [ ] |
| TF-14 | `refresh-gh-secrets.sh`: Learner Lab creds -> `gh secret set` on the service repos | new | [ ] |
| TF-15 | Outputs: `alb_dns`, `gateway_public_url`, `front_public_url`, `mq_amqps_endpoint` | `.state/gateway_public_url.txt`, `14-verify.sh` | [ ] |
| TF-16 | OAuth secrets for gateway delivered via SSM/Secrets Manager (spike 6) instead of `.state/google_oauth.env` | `16-update-gateway-oauth.sh` | [ ] |
| TF-17 | Retire legacy `deploy/aws/` scripts after parity (keep `14-verify.sh` logic as a check) | all, `99-cleanup.sh` -> `terraform destroy` | [ ] |

## Acceptance criteria

- `terraform apply` from empty reaches a working stack; a second `plan` shows no changes.
- Changing a service's task-def revision outside Terraform does not produce a plan diff.
- gateway `/health` OK, OpenAPI served, `/auth/login` returns 302, front returns 200.
- Scan flow works through Amazon MQ (AMQPS).
- No secrets or tfstate tracked in git.

## Checks

`terraform fmt -check`, `terraform validate`, `terraform plan`, `actionlint`, `shellcheck refresh-gh-secrets.sh`.

## Progress / Next step

Status: planned (docs only). Next: complete master Phase 1 spikes, then TF-01 and TF-02.
