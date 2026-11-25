# Terraform

This directory is the main stack. State lives in an S3 bucket (`<project>-tfstate-<account_id>`) with native S3 locking (`use_lockfile`, no DynamoDB).

The bucket is created by `scripts/bootstrap-state-bucket.sh` (AWS CLI), not by Terraform: in AWS Academy Learner Lab an SCP denies `s3:GetBucketObjectLockConfiguration`, which the aws provider calls on every read of `aws_s3_bucket`, so Terraform cannot manage any S3 bucket there.

## End-to-end deploy

This flow replaced the former imperative `deploy/aws/` scripts (removed in TF-17; `99-cleanup.sh` became `terraform destroy`). Run from the `infra` repo root with `export AWS_PROFILE=learnerlab`.

1. Bootstrap the state bucket (once): `BUCKET="$(scripts/bootstrap-state-bucket.sh | tail -1)"` ([One-time bootstrap](#one-time-bootstrap)).
2. Bootstrap the namespace: `export TF_VAR_namespace_arn="$(scripts/bootstrap-namespace.sh | tail -1)"` ([Cloud Map namespace](#cloud-map-namespace)).
3. Init the backend: `terraform -chdir=terraform init -backend-config=backend.hcl -backend-config="bucket=$BUCKET"` ([Init the main root](#init-the-main-root)).
4. Create the event stream and import it (once per lab; [Event stream](#event-stream)), then create the stack: `terraform -chdir=terraform apply`.
5. Build and push the images, then redeploy: `scripts/push-images.sh` (`--dry-run`, `--no-redeploy`, or service names for a subset; until each service repo has CI).
6. Set the Google client: register `gateway_public_url` + `/auth/callback` as the redirect URI in Google first, then `GOOGLE_CLIENT_ID=... GOOGLE_CLIENT_SECRET=... scripts/set-google-oauth.sh` ([Google OAuth client](#google-oauth-client)).
7. Check the stack: `scripts/verify-stack.sh` (gateway and front over HTTPS, ECS running vs desired; exits 1 on any failure).
8. After each lab start: `scripts/refresh-gh-secrets.sh` ([GitHub Actions credentials](#github-actions-credentials)).

Pause and resume with `desired_count` ([Pause and resume](#pause-and-resume)). Tear down with `terraform -chdir=terraform destroy`. The Cloud Map namespace and the state bucket are outside Terraform and stay; delete them by hand only if wanted (`aws servicediscovery delete-namespace`, and empty then delete the bucket including its versions).

`push-images.sh` and `verify-stack.sh` read `terraform output -json` and honor `TF_DATA_DIR`. `make verify` tests both against fake binaries (`scripts/test-push-images.sh`, `scripts/test-verify-stack.sh`).

## One-time bootstrap

The script is idempotent and safe to re-run. It creates the bucket only if missing, then enforces versioning, SSE-AES256, the full public access block and a TLS-only bucket policy, and reads each setting back. It prints the bucket name as its last stdout line. It never deletes anything and never calls object-lock APIs. `--dry-run` prints the planned commands.

```sh
export AWS_PROFILE=learnerlab
BUCKET="$(scripts/bootstrap-state-bucket.sh | tail -1)"
```

Run it from the `infra` repo root. `PROJECT` (default `security-app`) and `AWS_REGION` (default `us-east-1`) can be overridden.

## Init the main root

The bucket name is passed on the command line, not committed. Reason: it contains the account ID, and one `-backend-config` flag is simpler than generating a file.

```sh
export AWS_PROFILE=learnerlab
# BUCKET comes from the bootstrap step above
terraform init -backend-config=backend.hcl -backend-config="bucket=$BUCKET"
```

## Offline checks

`make verify` uses `init -backend=false`, so it needs no credentials and no bucket.

`make verify` also runs `scripts/test-bootstrap-state-bucket.sh`, which tests the script against a fake `aws` binary.

## Cloud Map namespace

The Service Connect namespace (`<project>.local`) also lives outside Terraform. The Learner Lab role is denied `servicediscovery:CreateHttpNamespace`, but ECS can create the namespace itself when a cluster is created with `--service-connect-defaults namespace=<name>`. The aws provider needs the namespace ARN, and the lab also denies `servicediscovery:GetNamespace`, so a data source cannot read it. The ARN comes in as the required variable `namespace_arn`; Terraform manages the real cluster and log groups (`ecs.tf`).

Run it before `terraform plan`/`apply` (idempotent; if the namespace is listed it does nothing and only prints the ARN):

```sh
export AWS_PROFILE=learnerlab
export TF_VAR_namespace_arn="$(scripts/bootstrap-namespace.sh | tail -1)"
```

It creates a throwaway cluster `<project>-ns-bootstrap` so ECS creates the namespace, waits until it is listable, then deletes the throwaway cluster (the namespace is kept). The last stdout line is the namespace ARN. `--dry-run` prints the planned commands. `make verify` tests it with `scripts/test-bootstrap-namespace.sh` against a fake `aws` binary.


## Task definition ownership

Terraform owns the task definition revision each app service runs (env, secrets, roles, logging; RF-18). `aws_ecs_service` does not ignore `task_definition`, so every `apply` points each service at the revision Terraform registered, and an env or secret change reaches the service in that same `apply`.

Each service repo's `deploy.yml` builds `<sha>` and `:latest`, copies the **latest revision of the service's family** (not the one the service runs), swaps only the image and registers a new revision. So a CI deploy never drops a change Terraform registered, even when that revision is not running yet.

After a CI deploy, the next `apply` shows the service moving back to Terraform's revision. That revision uses `:latest`, the same image CI just pushed, so the change only restarts the tasks once.

## Pause and resume

`desired_count` (default 1) drives all six ECS services and replaced the former pause/resume scripts:

```sh
terraform apply -var desired_count=0   # pause: stop every task
terraform apply                        # resume
```

The app services depend on the postgres and mongo services, so Terraform updates the data tier first. Data lives in ephemeral task storage, so a resumed stack starts with empty databases. The ALB, SQS, SNS and SSM resources stay up while paused.

## Event stream

`streaming.tf` creates the Kinesis Data Stream `security-events` (PROVISIONED, 1 shard, AWS default 24 h retention; `retention_period` is left unset because the lab SCP denies `IncreaseStreamRetentionPeriod`). The gateway, nmap-service, user-service and events-service receive its name as the plain environment variable `SECURITY_EVENTS_STREAM_NAME` (the front does not). Outputs: `security_events_stream_name`, `security_events_stream_arn`.

`events-service` (`app_services.tf`) is the internal read side of that stream (ES-04). It has its own ECR repository (`security-app/events-service`), ECS service `events-service`, Service Connect `publish` (`events-service:8080`), no ALB target group, and runs as `LabRole` like the other services. Its environment is `HTTP_HOST`, `HTTP_PORT`, `RUST_LOG`, `SECURITY_EVENTS_STREAM_NAME` and `AWS_REGION`. It requires the header `X-Gateway-Secret`, whose value is the SecureString `/security-app/events-service/gateway-shared-secret` (48 random alphanumeric characters, generated by Terraform, separate from the user-service secret). Terraform injects it as `GATEWAY_SHARED_SECRET` into events-service and as `EVENTS_SERVICE_SHARED_SECRET` into the gateway, which also receives `EVENTS_SERVICE_BASE_URL=http://events-service:8080`. Both gateway variables are harmless until the gateway proxies the admin feed to events-service (ES-03). On the next apply, push the first `events-service` image (`scripts/push-images.sh events-service`) before its task can start, and keep passing `TF_VAR_admin_bootstrap_emails`.

- No IAM resources: tasks run as `LabRole`, which reads and writes Kinesis from Fargate (verified in the KAP-00b spike).
- Variable `security_events_encryption` (`KMS` default, or `NONE`) controls server-side encryption with the AWS-managed key `alias/aws/kinesis`. Verified 2026-11-10: a Fargate task running as `LabRole` writes and reads a stream encrypted with that key. `NONE` stays as an escape hatch.
- The stream stays up while the stack is paused.
- In the Learner Lab, create the stream with the AWS CLI and import it before the first `apply`. On create the aws provider always calls `IncreaseStreamRetentionPeriod` (its schema defaults `retention_period` to 24), and the lab SCP denies it; on update it calls it only when retention changes. There is no `import` block because `terraform test` mock providers cannot import.

  ```sh
  aws kinesis create-stream --stream-name security-events --shard-count 1
  aws kinesis wait stream-exists --stream-name security-events
  terraform -chdir=terraform import aws_kinesis_stream.security_events security-events
  ```

## GitHub Actions credentials

The service repos deploy with the temporary Learner Lab credentials (the lab cannot create the IAM role GitHub OIDC needs). After each lab start, copy them into GitHub:

```sh
scripts/refresh-gh-secrets.sh --dry-run   # validate and list targets
scripts/refresh-gh-secrets.sh
```

It reads the `learnerlab` profile, checks it with `sts get-caller-identity` (an expired session aborts before any write), and sets the secrets `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN` and the variable `AWS_REGION` on `cloud-native-security-app/{user-service,events-service,nmap-service,gateway,front}`. Values reach `gh` on stdin and are never printed. Override with `AWS_PROFILE`, `AWS_REGION`, `GH_OWNER`, `REPOS`. `make verify` tests it with `scripts/test-refresh-gh-secrets.sh` against fake `aws` and `gh` binaries.

## Google OAuth client

Terraform creates `/security-app/gateway/google-client-id` and `/security-app/gateway/google-client-secret` as SSM SecureStrings with a placeholder value and ignores later value changes, so the real secret never enters Terraform or its state. After `apply`, store the real client and redeploy the gateway:

```sh
GOOGLE_CLIENT_ID=... GOOGLE_CLIENT_SECRET=... scripts/set-google-oauth.sh
```

Without those variables it reads the untracked local file `deploy/aws/.state/google_oauth.env` (left by the retired scripts; gitignored, never committed). Values reach `aws` through 0600 temp files, never argv, and are never printed. The Google redirect URI is the `gateway_public_url` output plus `/auth/callback`. `--dry-run` validates without writing. `make verify` tests it with `scripts/test-set-google-oauth.sh`.

## Report email (SMTP)

user-service emails the report to the scan owner when a scan completes. Terraform creates `/security-app/user-service/smtp-host`, `smtp-port`, `smtp-username` and `smtp-password` as SSM SecureStrings holding a placeholder (one space for host, username and password, because SSM rejects an empty value; `587` for the port) and ignores later value changes, so the password never enters Terraform or its state. ECS injects them through `secrets` as `SMTP_HOST`, `SMTP_PORT`, `SMTP_USERNAME` and `SMTP_PASSWORD`; LabRole is the execution role, so it already reads them. A blank `SMTP_HOST` disables the email: scans keep working and the history reports `disabled`. Until you run the steps below, email stays off.

Lab provider: a dedicated Gmail account (about 500 messages a day, enough for academic use).

1. Create the Gmail account and turn on 2-Step Verification.
2. In the Google account security page, create an App Password (16 characters). Use it as the SMTP password, never the account password.
3. After `apply`, store the settings and redeploy user-service:

```sh
SMTP_HOST=smtp.gmail.com SMTP_USERNAME=dedicated.account@gmail.com scripts/set-smtp.sh
```

The script prompts for the password without echo (or reads it from stdin, or `SMTP_PASSWORD`); `SMTP_PORT` defaults to 587 (STARTTLS, the default `SMTP_TLS`). Values reach `aws` through 0600 temp files, never argv, and are never printed. The sender defaults to the username. `--dry-run` validates without writing; A failed write restores the previous values of the parameters already written (a missing one goes back to its placeholder) and skips the redeploy; if a restore fails too, the script names the parameters that may be inconsistent. A failed `aws` call shows the first line of its error with the values redacted. The script needs only bash, coreutils, grep and the aws CLI. `--disable` restores the placeholders and redeploys, turning the email off. The same by hand: `aws ssm put-parameter --name /security-app/user-service/smtp-password --type SecureString --overwrite --value file://<tmpfile>` for each parameter, then `aws ecs update-service --cluster security-app-cluster-v2 --service user-service --force-new-deployment`. `make verify` tests the script with `scripts/test-set-smtp.sh`.

Local development: `docker compose up` starts Mailpit (`axllent/mailpit:v1.21`) and points user-service at it (`SMTP_HOST=mailpit`, port 1025, `SMTP_TLS=none`, no credentials). Read the mail at http://localhost:8025 (bound to localhost).

## Admin users

`admin_bootstrap_emails` (list, default empty) reaches user-service as `ADMIN_BOOTSTRAP_EMAILS`, comma separated. The list is authoritative: user-service grants the `admin` role to those emails and revokes it from everyone else at startup and on profile provisioning, so an empty list means no admins and the `/admin` panel is unreachable. Pass it at apply time instead of committing it:

```sh
TF_VAR_admin_bootstrap_emails='["admin@example.com"]' terraform -chdir=terraform apply
```

Every later `apply` must pass the same list: without it the default empty list revokes every admin.

## Network scan (IP-only mode)

Network mode scans an IP without SSH credentials and is limited to accounts with the `network_scan` permission.

| Variable | Default | Effect |
|---|---|---|
| `network_scan_emails` | `[]` | user-service `NETWORK_SCAN_EMAILS`, comma separated. Authoritative like the admin list: only these emails have the permission (empty = nobody). Same email validation as `admin_bootstrap_emails`. |
| `network_scan_allowed_cidrs` | `[]` | gateway `NETWORK_SCAN_ALLOWED_CIDRS`, comma separated. Empty leaves the variable unset: any target outside the gateway denylist is accepted. Each entry must be a valid CIDR. |
| `local_scan_timeout_secs` | `900` | nmap-service `MS_NMAP_LOCAL_SCAN_TIMEOUT_SECS`. |
| `nvd_enrichment_budget_secs` | `300` | Queue-only: seconds the requests visibility timeout budgets for NVD enrichment (nmap-service has no NVD timeout variable). Must be positive. |

nmap-service also gets `MS_NMAP_NVD_ENRICHMENT_ENABLED=true` and `MS_NMAP_NVD_CACHE_TTL_SECS=86400` (version-based CVEs come from NVD in both modes; without `MS_NMAP_NVD_API_KEY` NVD allows about 5 requests per 30 s and the Mongo cache absorbs repeats). Pass the lists at apply time and on every later apply, like the admin list:

```sh
TF_VAR_network_scan_emails='["scanner@example.com"]' \
TF_VAR_network_scan_allowed_cidrs='["172.31.0.0/16"]' terraform -chdir=terraform apply
```

The requests queue visibility timeout is `max(ssh connect + ssh command, local scan timeout) + nvd_enrichment_budget_secs + 60` seconds (1270 by default), so a message never reappears while a scan runs.

### nmap-service security group

nmap-service scans arbitrary targets, so it runs in its own group `security-app-nmap-sg` (outputs `nmap_sg_name`, `nmap_sg_id`), not in `security-app-internal-sg`:

- Egress: all (scan targets, ECR, SQS/SNS, Kinesis, Logs, SSM). No ingress: it is an SQS consumer with no port, and Service Connect is client-only.
- Mongo is reached through Service Connect, whose client proxy connects straight to the mongo task, so the internal SG has one extra rule: tcp/27017 from the nmap SG (`mongo_from_nmap`). Nothing else on the internal SG admits the nmap SG, so the gateway, user-service, events-service and Postgres do not accept its traffic.
- Scan targets must allow the nmap SG: `create-test-target.sh` and `create-weak-target.sh` open all TCP to it (plus the existing internal-SG rules). Re-run them against an existing target to add the rule.
- After applying this change, re-run `create-test-target.sh` and `create-weak-target.sh` for every existing scan target: they still only admit the internal SG, so until the nmap SG rule is added, scans from nmap-service time out over SSH.

Deploy order: apply Terraform, then roll out user-service and nmap-service before the gateway (the gateway checks the permission on user-service and publishes network-mode requests only nmap-service understands).

## Scan test target

`scripts/create-test-target.sh` creates a disposable Amazon Linux 2023 `t3.micro` (nmap installed, SSH password login) to test the network-credentials scan end to end. It stays outside Terraform on purpose: it is a throwaway lab target, not part of the platform. Apply the Terraform stack first; SSH (tcp/22) is allowed from `security-app-internal-sg` and all TCP from `security-app-nmap-sg` (the scanner), never from `0.0.0.0/0`.

```sh
scripts/create-test-target.sh            # create or reuse; prints the form values
scripts/create-test-target.sh --dry-run  # plan only
scripts/create-test-target.sh --destroy  # terminate the instance and delete its SG
```

In the front "Credenciales de red" form use the printed PRIVATE IP as `<ip>/32`, user `ec2-user` and the password (shown once, only at creation), sudo unchecked. sshd may need 1-2 minutes after creation. To reset the password, run `--destroy` and then create again. Overrides: `PROJECT`, `AWS_PROFILE`, `AWS_REGION`. `make verify` tests it with `scripts/test-create-test-target.sh`.

### Weak-config demo target

`scripts/create-weak-target.sh` is the same disposable target (Amazon Linux 2023 `t3.micro`, nmap, SSH password login, same form values) plus three deliberate misconfigurations on stock packages, so a scan reports confirmed findings. No malware, backdoored builds or exploit code: only insecure settings.

- tcp/80: nginx serving a world-readable `/.git/` directory (`autoindex on`) -> http-git.
- tcp/8443: nginx HTTPS (self-signed) with a weak 1024-bit Diffie-Hellman group -> ssl-dh-params.
- tcp/21: stock vsftpd with anonymous read-only access, passive mode off (no extra ports) -> ftp-anon.
- tcp/22: sshd with password login, as in the scan test target.

All four ports are allowed only from `security-app-internal-sg`, and all TCP from `security-app-nmap-sg` (network mode probes every port); the target security group is `security-app-weak-target-sg`. Never from `0.0.0.0/0`. For demos only: create it, scan it, destroy it.

```sh
scripts/create-weak-target.sh            # create or reuse; prints the form values
scripts/create-weak-target.sh --dry-run  # plan only
scripts/create-weak-target.sh --destroy  # terminate the instance and delete its SG
```

user-data needs ~1-2 min after creation. Same overrides as above. `make verify` tests it with `scripts/test-create-weak-target.sh`.


## Connecting Wazuh and Suricata

The gateway can receive Wazuh alerts (including Suricata signatures) and show them in the admin panel tab "Alertas IDS". This repo only prepares the receiving side. It does not deploy Wazuh, Suricata, OpenSearch or any EC2 instance.

### Enable it

`siem_enabled` (bool, default `false`). When `true`, `apply` creates:

- the SSM SecureString `/security-app/gateway/siem-ingest-token` (48 random alphanumeric characters), injected into the gateway through `secrets` as `SIEM_INGEST_TOKEN`, which mounts the route;
- `SIEM_ENABLED=true` on events-service, which starts aggregating `siem.alert` events.

When `false`, none of that exists. events-service gets no `SIEM_ENABLED` at all (its default is off). LabRole already reads every SSM parameter the tasks use, so no IAM change is needed. The output `siem_ingest_token_parameter` holds the parameter name (never the value).

```sh
TF_VAR_siem_enabled=true terraform -chdir=terraform apply   # keep passing your other TF_VAR_* values
aws ssm get-parameter --name /security-app/gateway/siem-ingest-token --with-decryption --query Parameter.Value --output text
```

Treat the token as a secret. The `apply` points the gateway and events-service at their new task definition revisions, so they pick it up with no extra redeploy ([Task definition ownership](#task-definition-ownership)).

### Wazuh manager: custom integration

Wazuh runs custom integrations through `integratord`. The script must live in `/var/ossec/integrations/`, be named `custom-*`, be executable and be owned by `root:wazuh`. `integratord` calls it with the alert file, the `api_key` and the `hook_url`. Syntax follows the Wazuh documentation (custom integrations); adjust it to your Wazuh version.

In `/var/ossec/etc/ossec.conf` on the manager:

```xml
<integration>
  <name>custom-security-app</name>
  <hook_url>https://GATEWAY_HOST/api/integrations/siem/alerts</hook_url>
  <api_key>TOKEN_FROM_SSM</api_key>
  <level>7</level>
  <alert_format>json</alert_format>
</integration>
```

`level` is the minimum Wazuh rule level to forward. The token sits in `ossec.conf` in clear text, so restrict that file. Use the public gateway URL (the `gateway_public_url` output); the gateway listens on HTTPS only.

`/var/ossec/integrations/custom-security-app` (Python 3, standard library only):

```python
#!/usr/bin/env python3
import json
import sys
import urllib.request

alert_file, token, url = sys.argv[1], sys.argv[2], sys.argv[3]
with open(alert_file) as f:
    alert = json.load(f)
req = urllib.request.Request(
    url,
    data=json.dumps(alert).encode(),
    headers={"Content-Type": "application/json", "Authorization": f"Bearer {token}"},
    method="POST",
)
try:
    urllib.request.urlopen(req, timeout=10)
except Exception as exc:  # integratord logs stderr; Wazuh does not retry
    print(f"custom-security-app: {exc}", file=sys.stderr)
    sys.exit(1)
```

Then `chmod 750`, `chown root:wazuh` and restart the manager (`systemctl restart wazuh-manager`). The location, `custom-` prefix, permissions, argument order and the extensionless script with an interpreter line match the Wazuh documentation (integration with external APIs, checked 2026-11-24); not run against a live Wazuh here.

### Suricata on the scan target

Run Suricata on the host you scan and let the Wazuh agent on that host read its `eve.json`. In the agent's `ossec.conf`:

```xml
<localfile>
  <log_format>json</log_format>
  <location>/var/log/suricata/eve.json</location>
</localfile>
```

The Wazuh ruleset decodes Suricata alerts, and the alert JSON carries `data.alert.signature`, which the gateway maps to the `signature` field. The `<localfile>` block matches the Wazuh Suricata guide; the `data.*` field names come from Suricata's `eve.json` and are not spelled out in the Wazuh documentation, so check them in a real alert (RF-11). The agent name becomes `agent.name`, which the endpoint requires.

Network scan mode (IP-only scans, see above) is the traffic Suricata sees: the nmap probes against the target show up as IDS alerts next to the scan result. Only hosts that run a Wazuh agent with Suricata report anything.

### Sizing

The Wazuh manager and indexer need an EC2 instance of about 8 GB RAM. They do not fit Fargate or the Learner Lab budget here, and they are not provisioned by this repo.

### Endpoint behavior

`POST /api/integrations/siem/alerts` with `Authorization: Bearer <token>` and the Wazuh alert JSON.

| Status | When |
| --- | --- |
| 202 | Accepted and published to the event stream. |
| 401 | Missing or wrong token. Also when SIEM is disabled: the route is not mounted and behaves like any unknown path, so it cannot be probed. |
| 413 | Body over 64 KiB. |
| 422 | A required field is missing, such as `agent.name`. |
| 429 | More than 120 requests per 60 s. Wazuh does not retry, so a burst over the limit is dropped. |
| 503 | The token is set but no event stream is configured. |

Severity is derived from the Wazuh rule level (0..16) with the project's own bands: 0-6 low, 7-9 medium, 10-12 high, 13-16 critical. Wazuh titles each level but does not group them into severities; level 16 is reserved for custom rules.

Local development: `docker-compose.yml` passes `SIEM_ENABLED` (default `false`) to events-service and `SIEM_INGEST_TOKEN` (default empty, route off) to the gateway. For example `SIEM_ENABLED=true SIEM_INGEST_TOKEN=dev-siem-token docker compose up`.
