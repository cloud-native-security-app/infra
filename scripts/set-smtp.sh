#!/usr/bin/env bash
# Stores the SMTP settings of user-service (report email) in SSM and redeploys user-service.
# Terraform only seeds blank placeholders in these parameters (ignore_changes = [value]), so the
# password never passes through Terraform or its state.
#
# Usage: scripts/set-smtp.sh [--dry-run] [--disable]
#   Reads SMTP_HOST, SMTP_PORT (default 587), SMTP_USERNAME and SMTP_PASSWORD from the
#   environment; anything missing is prompted. The password is read without echo from the
#   terminal (or stdin when piped), never from argv.
#   --disable: write the blank placeholder to all four parameters (email disabled).
#   --dry-run: validate inputs and credentials, write nothing.
#   env: PROJECT (default security-app), AWS_PROFILE (default learnerlab),
#        AWS_REGION (default us-east-1), CLUSTER (default ${PROJECT}-cluster-v2)
#
# Lab provider: smtp.gmail.com, port 587 (STARTTLS), a dedicated Gmail account with 2-Step
# Verification and an App Password. Values reach aws through 0600 temp files (file://) and are
# never printed.
set -euo pipefail

PROJECT="${PROJECT:-security-app}"
AWS_PROFILE="${AWS_PROFILE:-learnerlab}"
AWS_REGION="${AWS_REGION:-us-east-1}"
CLUSTER="${CLUSTER:-${PROJECT}-cluster-v2}"
DRY_RUN=0
DISABLE=0

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --disable) DISABLE=1 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

log() { echo "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

# aws-cli v1 ignores AWS_REGION, so the region is always explicit.
awsr() { aws --profile "$AWS_PROFILE" --region "$AWS_REGION" "$@"; }

# SSM rejects an empty value; a single space is the "unset" placeholder (blank = disabled).
BLANK=" "

if [ "$DISABLE" -eq 1 ]; then
  SMTP_HOST="$BLANK" SMTP_PORT="$BLANK" SMTP_USERNAME="$BLANK" SMTP_PASSWORD="$BLANK"
else
  if [ -z "${SMTP_HOST:-}" ]; then
    read -r -p "SMTP host (e.g. smtp.gmail.com): " SMTP_HOST
  fi
  SMTP_PORT="${SMTP_PORT:-587}"
  if [ -z "${SMTP_USERNAME:-}" ]; then
    read -r -p "SMTP username (the Gmail address): " SMTP_USERNAME
  fi
  if [ -z "${SMTP_PASSWORD:-}" ]; then
    printf 'SMTP password (App Password, not echoed): ' >&2
    read -r -s SMTP_PASSWORD
    echo >&2
  fi
  [ -n "$SMTP_HOST" ] && [ -n "$SMTP_USERNAME" ] && [ -n "$SMTP_PASSWORD" ] ||
    die "host, username and password are all required (use --disable to turn the email off)"
  case "$SMTP_PORT" in
    '' | *[!0-9]*) die "SMTP_PORT must be a number" ;;
  esac
fi

awsr sts get-caller-identity --query Account --output text >/dev/null 2>&1 ||
  die "credentials in profile '$AWS_PROFILE' are invalid or expired; refresh them from the Learner Lab"

PARAM_PREFIX="/${PROJECT}/user-service"
if [ "$DRY_RUN" -eq 1 ]; then
  log "DRY-RUN: would put $PARAM_PREFIX/smtp-{host,port,username,password} (SecureString)"
  log "DRY-RUN: would redeploy service user-service in cluster $CLUSTER"
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

put "$PARAM_PREFIX/smtp-host" "$SMTP_HOST"
put "$PARAM_PREFIX/smtp-port" "$SMTP_PORT"
put "$PARAM_PREFIX/smtp-username" "$SMTP_USERNAME"
put "$PARAM_PREFIX/smtp-password" "$SMTP_PASSWORD"

# ECS reads `secrets` only when a task starts, so new tasks pick up the values.
awsr ecs update-service --cluster "$CLUSTER" --service user-service --force-new-deployment >/dev/null
if [ "$DISABLE" -eq 1 ]; then
  log "user-service redeploying with the report email disabled"
else
  log "user-service redeploying with the new SMTP settings"
fi
