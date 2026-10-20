# Terraform

This directory is the main stack. State lives in an S3 bucket (`<project>-tfstate-<account_id>`) with native S3 locking (`use_lockfile`, no DynamoDB).

The bucket is created by `scripts/bootstrap-state-bucket.sh` (AWS CLI), not by Terraform: in AWS Academy Learner Lab an SCP denies `s3:GetBucketObjectLockConfiguration`, which the aws provider calls on every read of `aws_s3_bucket`, so Terraform cannot manage any S3 bucket there.

## End-to-end deploy

This flow replaced the former imperative `deploy/aws/` scripts (removed in TF-17; `99-cleanup.sh` became `terraform destroy`). Run from the `infra` repo root with `export AWS_PROFILE=learnerlab`.

1. Bootstrap the state bucket (once): `BUCKET="$(scripts/bootstrap-state-bucket.sh | tail -1)"` ([One-time bootstrap](#one-time-bootstrap)).
2. Bootstrap the namespace: `export TF_VAR_namespace_arn="$(scripts/bootstrap-namespace.sh | tail -1)"` ([Cloud Map namespace](#cloud-map-namespace)).
3. Init the backend: `terraform -chdir=terraform init -backend-config=backend.hcl -backend-config="bucket=$BUCKET"` ([Init the main root](#init-the-main-root)).
4. Create the stack: `terraform -chdir=terraform apply`.
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


## Pause and resume

`desired_count` (default 1) drives all six ECS services and replaced the former pause/resume scripts:

```sh
terraform apply -var desired_count=0   # pause: stop every task
terraform apply                        # resume
```

The app services depend on the postgres and mongo services, so Terraform updates the data tier first. Data lives in ephemeral task storage, so a resumed stack starts with empty databases. The ALB, SQS, SNS and SSM resources stay up while paused.

## GitHub Actions credentials

The service repos deploy with the temporary Learner Lab credentials (the lab cannot create the IAM role GitHub OIDC needs). After each lab start, copy them into GitHub:

```sh
scripts/refresh-gh-secrets.sh --dry-run   # validate and list targets
scripts/refresh-gh-secrets.sh
```

It reads the `learnerlab` profile, checks it with `sts get-caller-identity` (an expired session aborts before any write), and sets the secrets `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN` and the variable `AWS_REGION` on `cloud-native-security-app/{user-service,nmap-service,gateway,front}`. Values reach `gh` on stdin and are never printed. Override with `AWS_PROFILE`, `AWS_REGION`, `GH_OWNER`, `REPOS`. `make verify` tests it with `scripts/test-refresh-gh-secrets.sh` against fake `aws` and `gh` binaries.

## Google OAuth client

Terraform creates `/security-app/gateway/google-client-id` and `/security-app/gateway/google-client-secret` as SSM SecureStrings with a placeholder value and ignores later value changes, so the real secret never enters Terraform or its state. After `apply`, store the real client and redeploy the gateway:

```sh
GOOGLE_CLIENT_ID=... GOOGLE_CLIENT_SECRET=... scripts/set-google-oauth.sh
```

Without those variables it reads the untracked local file `deploy/aws/.state/google_oauth.env` (left by the retired scripts; gitignored, never committed). Values reach `aws` through 0600 temp files, never argv, and are never printed. The Google redirect URI is the `gateway_public_url` output plus `/auth/callback`. `--dry-run` validates without writing. `make verify` tests it with `scripts/test-set-google-oauth.sh`.

## Scan test target

`scripts/create-test-target.sh` creates a disposable Amazon Linux 2023 `t3.micro` (nmap installed, SSH password login) to test the network-credentials scan end to end. It stays outside Terraform on purpose: it is a throwaway lab target, not part of the platform. Apply the Terraform stack first; SSH (tcp/22) is allowed only from `security-app-internal-sg`, never from `0.0.0.0/0`.

```sh
scripts/create-test-target.sh            # create or reuse; prints the form values
scripts/create-test-target.sh --dry-run  # plan only
scripts/create-test-target.sh --destroy  # terminate the instance and delete its SG
```

In the front "Credenciales de red" form use the printed PRIVATE IP as `<ip>/32`, user `ec2-user` and the password (shown once, only at creation), sudo unchecked. sshd may need 1-2 minutes after creation. To reset the password, run `--destroy` and then create again. Overrides: `PROJECT`, `AWS_PROFILE`, `AWS_REGION`. `make verify` tests it with `scripts/test-create-test-target.sh`.
