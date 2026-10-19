#!/usr/bin/env bash
# Stores the real Google OAuth client of the gateway in SSM and redeploys the gateway.
# Terraform only seeds placeholders in these parameters (ignore_changes = [value]), so the
# secret never passes through Terraform or its state. Replaces 16-update-gateway-oauth.sh.
#
# Usage: GOOGLE_CLIENT_ID=... GOOGLE_CLIENT_SECRET=... scripts/set-google-oauth.sh [--dry-run]
#   Without the env vars it reads OAUTH_FILE (default deploy/aws/.state/google_oauth.env,
#   written by the legacy scripts).
#   env: PROJECT (default security-app), AWS_PROFILE (default learnerlab),
#        AWS_REGION (default us-east-1), CLUSTER (default ${PROJECT}-cluster-v2)
#   --dry-run: validate inputs and credentials, write nothing.
#
# Values reach aws through 0600 temp files (file://), never argv, and are never printed.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="${PROJECT:-security-app}"
AWS_PROFILE="${AWS_PROFILE:-learnerlab}"
AWS_REGION="${AWS_REGION:-us-east-1}"
CLUSTER="${CLUSTER:-${PROJECT}-cluster-v2}"
OAUTH_FILE="${OAUTH_FILE:-$REPO_ROOT/deploy/aws/.state/google_oauth.env}"
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
awsr() { aws --profile "$AWS_PROFILE" --region "$AWS_REGION" "$@"; }

if [ -z "${GOOGLE_CLIENT_ID:-}" ] && [ -f "$OAUTH_FILE" ]; then
  # Written by the legacy save_google_oauth with printf %q.
  # shellcheck disable=SC1090
  source "$OAUTH_FILE"
fi
[ -n "${GOOGLE_CLIENT_ID:-}" ] && [ -n "${GOOGLE_CLIENT_SECRET:-}" ] ||
  die "set GOOGLE_CLIENT_ID and GOOGLE_CLIENT_SECRET (or provide $OAUTH_FILE)"

awsr sts get-caller-identity --query Account --output text >/dev/null 2>&1 ||
  die "credentials in profile '$AWS_PROFILE' are invalid or expired; refresh them from the Learner Lab"

PARAM_PREFIX="/${PROJECT}/gateway"
if [ "$DRY_RUN" -eq 1 ]; then
  log "DRY-RUN: would put $PARAM_PREFIX/google-client-id and $PARAM_PREFIX/google-client-secret (SecureString)"
  log "DRY-RUN: would redeploy service gateway in cluster $CLUSTER"
  exit 0
fi

TMP="$(umask 077 && mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

put() {
  local name="$1" value="$2" file="$TMP/value"
  printf '%s' "$value" >"$file"
  awsr ssm put-parameter --name "$name" --type SecureString --overwrite \
    --value "file://$file" >/dev/null
  rm -f "$file"
  log "updated $name"
}

put "$PARAM_PREFIX/google-client-id" "$GOOGLE_CLIENT_ID"
put "$PARAM_PREFIX/google-client-secret" "$GOOGLE_CLIENT_SECRET"

# ECS reads `secrets` only when a task starts, so new tasks pick up the values.
awsr ecs update-service --cluster "$CLUSTER" --service gateway --force-new-deployment >/dev/null
log "gateway redeploying with the new OAuth client"
