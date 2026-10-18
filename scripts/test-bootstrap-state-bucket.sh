#!/usr/bin/env bash
# Offline tests for bootstrap-state-bucket.sh: a fake `aws` on PATH logs argv.
# Needs no credentials and no network.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="$SCRIPT_DIR/bootstrap-state-bucket.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/bin"
cat >"$WORK/bin/aws" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >>"$FAKE_AWS_LOG"
case "$*" in
  *"sts get-caller-identity"*) echo "123456789012" ;;
  *"s3api head-bucket"*) [ "${FAKE_BUCKET_EXISTS:-0}" = "1" ] || exit 255 ;;
  *"s3api get-bucket-versioning"*) echo "Enabled" ;;
  *"s3api get-bucket-encryption"*) echo "AES256" ;;
  *"s3api get-public-access-block"*) printf 'True\tTrue\tTrue\tTrue\n' ;;
  *"s3api get-bucket-policy"*)
    echo '{"Statement":[{"Effect":"Deny","Action":"s3:*","Condition":{"Bool":{"aws:SecureTransport":"false"}}}]}' ;;
esac
exit 0
FAKE
chmod +x "$WORK/bin/aws"

fail=0
err() { echo "FAIL: $*" >&2; fail=1; }

# run_case <name> <bucket_exists> [script args...]; sets OUT, ERR, LOG, RC
run_case() {
  local name="$1" exists="$2"
  shift 2
  LOG="$WORK/$name.log"
  : >"$LOG"
  RC=0
  PATH="$WORK/bin:$PATH" FAKE_AWS_LOG="$LOG" FAKE_BUCKET_EXISTS="$exists" \
    bash "$TARGET" "$@" >"$WORK/$name.out" 2>"$WORK/$name.err" || RC=$?
  OUT="$WORK/$name.out"
  ERR="$WORK/$name.err"
}

has() { rg -q -- "$1" "$LOG"; }

# 1. bucket missing: created and fully configured
run_case missing 0
[ "$RC" -eq 0 ] || err "missing: exit $RC"
[ "$(tail -1 "$OUT")" = "security-app-tfstate-123456789012" ] || err "missing: last stdout line is not the bucket name"
has 's3api create-bucket --bucket security-app-tfstate-123456789012' || err "missing: create-bucket not called"
has '--region us-east-1' || err "missing: --region not passed"
has 's3api put-bucket-versioning .*Status=Enabled' || err "missing: versioning not enabled"
has 's3api put-bucket-encryption .*AES256' || err "missing: encryption not set"
has 's3api put-public-access-block .*BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true' || err "missing: public access block not set"
has 's3api put-bucket-policy .*aws:SecureTransport' || err "missing: policy without SecureTransport"
has 's3api put-bucket-policy .*"Effect":"Deny"' || err "missing: policy without Deny"
has 's3api put-bucket-policy .*arn:aws:s3:::security-app-tfstate-123456789012/\*' || err "missing: policy does not cover objects"
has 'object-lock|ObjectLock' && err "missing: object-lock API called"
has ' delete' && err "missing: a delete call was made"

# 2. bucket present: no create-bucket, settings re-applied
run_case present 1
[ "$RC" -eq 0 ] || err "present: exit $RC"
has 's3api create-bucket' && err "present: create-bucket called on existing bucket"
has 's3api put-bucket-versioning' || err "present: versioning not re-applied"
[ "$(tail -1 "$OUT")" = "security-app-tfstate-123456789012" ] || err "present: last stdout line is not the bucket name"

# 3. env overrides
PROJECT=demo run_case project 0
[ "$(tail -1 "$OUT")" = "demo-tfstate-123456789012" ] || err "PROJECT override ignored"

# 4. dry-run: no mutating call, plan printed on stderr, bucket name still last
run_case dry 0 --dry-run
[ "$RC" -eq 0 ] || err "dry-run: exit $RC"
has 's3api (create-bucket|put-)' && err "dry-run: mutating call executed"
rg -q 'create-bucket' "$ERR" || err "dry-run: plan not printed"
[ "$(tail -1 "$OUT")" = "security-app-tfstate-123456789012" ] || err "dry-run: last stdout line is not the bucket name"

[ "$fail" -eq 0 ] && echo "test-bootstrap-state-bucket: OK"
exit "$fail"
