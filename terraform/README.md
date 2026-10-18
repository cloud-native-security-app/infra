# Terraform

This directory is the main stack. State lives in an S3 bucket (`<project>-tfstate-<account_id>`) with native S3 locking (`use_lockfile`, no DynamoDB).

The bucket is created by `scripts/bootstrap-state-bucket.sh` (AWS CLI), not by Terraform: in AWS Academy Learner Lab an SCP denies `s3:GetBucketObjectLockConfiguration`, which the aws provider calls on every read of `aws_s3_bucket`, so Terraform cannot manage any S3 bucket there.

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

The Service Connect namespace (`<project>.local`) also lives outside Terraform. The Learner Lab role is denied `servicediscovery:CreateHttpNamespace`, but ECS can create the namespace itself when a cluster is created with `--service-connect-defaults namespace=<name>`. The aws provider needs the namespace ARN, so Terraform reads it with a data source (`ecs.tf`) and manages the real cluster and log groups.

Run once before the first `terraform apply` (idempotent; if the namespace is listed it does nothing):

```sh
AWS_PROFILE=learnerlab scripts/bootstrap-namespace.sh
```

It creates a throwaway cluster `<project>-ns-bootstrap` so ECS creates the namespace, waits until it is listable, then deletes the throwaway cluster (the namespace is kept). The last stdout line is the namespace ARN. `--dry-run` prints the planned commands. `make verify` tests it with `scripts/test-bootstrap-namespace.sh` against a fake `aws` binary.

