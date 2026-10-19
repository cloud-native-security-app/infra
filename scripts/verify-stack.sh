#!/usr/bin/env bash
# Smoke-checks the deployed stack: gateway and front over HTTPS through the ALB, and the
# ECS services (running == desired, ACTIVE). Replaces the former 14-verify.sh.
#
# Usage: scripts/verify-stack.sh
#   env: AWS_PROFILE (default learnerlab), AWS_REGION (default us-east-1)
#        TF_DATA_DIR is honored by terraform if the caller sets it.
#
# Terraform outputs used: gateway_public_url, front_public_url, cluster_name, service_names.
# Prints `[OK]`/`[FAIL] <name>: <detail>` per check and exits 1 if any check failed.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AWS_PROFILE="${AWS_PROFILE:-learnerlab}"
AWS_REGION="${AWS_REGION:-us-east-1}"

for arg in "$@"; do
  echo "unknown argument: $arg" >&2; exit 2
done

log() { echo "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

# aws-cli v1 ignores AWS_REGION, so profile and region are always explicit.
awsr() { aws --profile "$AWS_PROFILE" --region "$AWS_REGION" "$@"; }
tf_outputs() { terraform -chdir="$REPO_ROOT/terraform" output -json; }

if ! awsr sts get-caller-identity --query Account --output text >/dev/null 2>&1; then
  die "credentials in profile '$AWS_PROFILE' are invalid or expired; refresh the Learner Lab credentials (AWS Details -> AWS CLI) into ~/.aws/credentials"
fi

OUTPUTS="$(tf_outputs)" || die "terraform output failed; run 'terraform init' in terraform/ first"
out() { jq -r "$1" <<<"$OUTPUTS"; }
GATEWAY_URL="$(out '.gateway_public_url.value // empty')"
FRONT_URL="$(out '.front_public_url.value // empty')"
CLUSTER="$(out '.cluster_name.value // empty')"
[ -n "$GATEWAY_URL" ] && [ -n "$FRONT_URL" ] && [ -n "$CLUSTER" ] \
  || die "terraform outputs are missing; the stack is not applied yet (run 'terraform apply' in terraform/)"
mapfile -t SERVICES < <(out '.service_names.value // [] | .[]')
[ "${#SERVICES[@]}" -gt 0 ] || die "terraform has no service_names output; the stack is not applied yet"

PASS=0
FAILED=0
ok() { echo "[OK] $1: $2"; PASS=$((PASS + 1)); }
bad() { echo "[FAIL] $1: $2"; FAILED=$((FAILED + 1)); }

# http_check <name> <url> <expected-code>
# -k because the ALB certificate is self-signed.
http_check() {
  local name="$1" url="$2" want="$3" got
  got="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 "$url" || true)"
  if [ "$got" = "$want" ]; then ok "$name" "$url -> $got"; else bad "$name" "$url -> ${got:-no response} (expected $want)"; fi
}

http_check "gateway health" "$GATEWAY_URL/health" 200
http_check "gateway openapi" "$GATEWAY_URL/api/openapi.json" 200
# 302 = redirect to Google; the OAuth round trip itself is not exercised here.
http_check "gateway login" "$GATEWAY_URL/auth/login" 302
http_check "front" "$FRONT_URL/" 200

# ECS: one row per service, tab separated by --output text.
ROWS="$(awsr ecs describe-services --cluster "$CLUSTER" --services "${SERVICES[@]}" \
  --query 'services[].[serviceName,status,runningCount,desiredCount]' --output text || true)"
echo
printf '%-16s %-9s %-8s %s\n' SERVICE STATUS RUNNING DESIRED
for svc in "${SERVICES[@]}"; do
  row="$(awk -F'\t' -v s="$svc" '$1 == s' <<<"$ROWS")"
  if [ -z "$row" ]; then
    printf '%-16s %s\n' "$svc" "(not found)"
    bad "ecs $svc" "service not found in cluster $CLUSTER"
    continue
  fi
  IFS=$'\t' read -r _ status running desired <<<"$row"
  printf '%-16s %-9s %-8s %s\n' "$svc" "$status" "$running" "$desired"
  if [ "$status" = "ACTIVE" ] && [ "$running" = "$desired" ]; then
    ok "ecs $svc" "$running/$desired running"
  else
    bad "ecs $svc" "status $status, running $running of desired $desired"
  fi
done

echo
echo "$PASS passed, $FAILED failed"
if [ "$FAILED" -gt 0 ]; then
  cat <<HINTS

If something failed, check in this order:
1. aws ecs describe-services --cluster $CLUSTER --services <svc> --query 'services[0].events'
2. aws logs filter-log-events --log-group-name /ecs/security-app/<svc> --query 'events[-20:].message' --output text
   (aws-cli v1 has no "logs tail")
   - user-service: "DatabaseConnectionFailed" is a boot race with postgres; ECS retries on its own
   - gateway and nmap-service cannot process scans until MSG-GW / MSG-NM (SNS/SQS messaging) land;
     they may restart or stay unhealthy until then
3. aws elbv2 describe-target-health --target-group-arn <tg-arn>   (gateway and front only)
4. A service paused with desired_count=0 shows running 0 of desired 0 and passes; HTTP checks fail while paused.

user-service has no target group (not exposed to the internet): verify it through logs only.
HINTS
  exit 1
fi
