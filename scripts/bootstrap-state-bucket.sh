#!/usr/bin/env bash
# Idempotent bootstrap of the Terraform state bucket (AWS CLI, no Terraform).
# Terraform cannot manage aws_s3_bucket in AWS Academy Learner Lab: an SCP denies
# s3:GetBucketObjectLockConfiguration, which the provider calls on every read.
#
# Usage: BUCKET="$(scripts/bootstrap-state-bucket.sh | tail -1)"
#   env: PROJECT (default security-app), AWS_REGION (default us-east-1), AWS_PROFILE
#   --dry-run: print the planned AWS CLI commands, execute no mutating call.
# Never calls object-lock APIs. Never deletes anything.
set -euo pipefail

PROJECT="${PROJECT:-security-app}"
AWS_REGION="${AWS_REGION:-us-east-1}"
DRY_RUN=0

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

log() { echo "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

# aws-cli v1 ignores AWS_REGION, so the region is always explicit.
awsr() { aws --region "$AWS_REGION" "$@"; }

# Mutating calls: printed only in dry-run, executed otherwise.
mutate() {
  if [ "$DRY_RUN" -eq 1 ]; then
    log "DRY-RUN: aws --region $AWS_REGION $*"
  else
    awsr "$@" >/dev/null
  fi
}

ACCOUNT_ID="$(awsr sts get-caller-identity --query Account --output text)"
[ -n "$ACCOUNT_ID" ] || die "could not resolve the account ID"
BUCKET="${PROJECT}-tfstate-${ACCOUNT_ID}"

POLICY="$(printf '{"Version":"2012-10-17","Statement":[{"Sid":"DenyInsecureTransport","Effect":"Deny","Principal":"*","Action":"s3:*","Resource":["arn:aws:s3:::%s","arn:aws:s3:::%s/*"],"Condition":{"Bool":{"aws:SecureTransport":"false"}}}]}' "$BUCKET" "$BUCKET")"

if awsr s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1; then
  log "bucket $BUCKET exists; re-applying settings"
else
  log "bucket $BUCKET missing; creating"
  if [ "$AWS_REGION" = "us-east-1" ]; then
    mutate s3api create-bucket --bucket "$BUCKET"
  else
    mutate s3api create-bucket --bucket "$BUCKET" \
      --create-bucket-configuration "LocationConstraint=$AWS_REGION"
  fi
fi

mutate s3api put-bucket-versioning --bucket "$BUCKET" \
  --versioning-configuration Status=Enabled
mutate s3api put-bucket-encryption --bucket "$BUCKET" \
  --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
mutate s3api put-public-access-block --bucket "$BUCKET" \
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
mutate s3api put-bucket-policy --bucket "$BUCKET" --policy "$POLICY"

if [ "$DRY_RUN" -eq 0 ]; then
  v="$(awsr s3api get-bucket-versioning --bucket "$BUCKET" --query Status --output text)"
  [ "$v" = "Enabled" ] || die "versioning is '$v', expected Enabled"

  e="$(awsr s3api get-bucket-encryption --bucket "$BUCKET" \
    --query 'ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm' --output text)"
  [ "$e" = "AES256" ] || die "encryption is '$e', expected AES256"

  p="$(awsr s3api get-public-access-block --bucket "$BUCKET" \
    --query '[PublicAccessBlockConfiguration.BlockPublicAcls,PublicAccessBlockConfiguration.IgnorePublicAcls,PublicAccessBlockConfiguration.BlockPublicPolicy,PublicAccessBlockConfiguration.RestrictPublicBuckets]' \
    --output text | tr -s '[:space:]' ' ')"
  [ "$p" = "True True True True " ] || [ "$p" = "True True True True" ] || die "public access block is '$p', expected all True"

  pol="$(awsr s3api get-bucket-policy --bucket "$BUCKET" --query Policy --output text)"
  pol="${pol//[[:space:]]/}"
  for needle in '"Effect":"Deny"' 'aws:SecureTransport' '"false"'; do
    case "$pol" in
      *"$needle"*) ;;
      *) die "bucket policy does not contain $needle" ;;
    esac
  done
  log "verified: versioning, SSE AES256, public access block, TLS-only policy"
fi

echo "$BUCKET"
