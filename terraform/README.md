# Terraform

Two root modules:

- `bootstrap/` creates only the state bucket (`<project>-tfstate-<account_id>`). It uses local state (gitignored).
- `.` (this directory) is the main stack. State lives in that bucket with native S3 locking (`use_lockfile`, no DynamoDB).

## One-time bootstrap

```sh
export AWS_PROFILE=learnerlab
terraform -chdir=bootstrap init
terraform -chdir=bootstrap apply
```

## Init the main root

The bucket name is passed on the command line, not committed. Reason: it contains the account ID, and one `-backend-config` flag is simpler than generating a file.

```sh
export AWS_PROFILE=learnerlab
BUCKET="$(terraform -chdir=bootstrap output -raw state_bucket_name)"
terraform init -backend-config=backend.hcl -backend-config="bucket=$BUCKET"
```

## Offline checks

`make verify` uses `init -backend=false` for both roots, so it needs no credentials and no bucket.

The bootstrap bucket has `prevent_destroy`. Keep `bootstrap/terraform.tfstate` (local, gitignored): losing it means importing the bucket again.
