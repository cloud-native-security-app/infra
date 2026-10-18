#!/usr/bin/env bash
# Asserts the S3 backend wiring (terraform tests cannot inspect backend blocks).
# Offline: reads files only.
set -euo pipefail

INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="$INFRA_DIR/terraform"

fail=0
err() { echo "FAIL: $*" >&2; fail=1; }

# Partial backend: type only, so the bucket name never lands in git.
rg -q '^\s*backend "s3" \{\s*\}' "$TF_DIR/versions.tf" || err "versions.tf must declare an empty backend \"s3\" {} block"

cfg="$TF_DIR/backend.hcl"
if [ -f "$cfg" ]; then
  rg -q '^key\s*=\s*"[^"]+"' "$cfg" || err "backend.hcl: key missing"
  rg -q '^region\s*=\s*"us-east-1"' "$cfg" || err "backend.hcl: region must be us-east-1"
  rg -q '^use_lockfile\s*=\s*true' "$cfg" || err "backend.hcl: use_lockfile must be true"
  rg -q '^encrypt\s*=\s*true' "$cfg" || err "backend.hcl: encrypt must be true"
  rg -q '^\s*bucket\s*=' "$cfg" && err "backend.hcl: bucket must not be committed"
  rg -q '^\s*dynamodb_table\s*=' "$cfg" && err "backend.hcl: no DynamoDB; use native locking"
else
  err "terraform/backend.hcl not found"
fi

[ "$fail" -eq 0 ] && echo "check-backend: OK"
exit "$fail"
