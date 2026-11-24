#!/usr/bin/env bash
# Stores the SMTP settings of user-service (report email) in SSM and redeploys user-service.
# Terraform only seeds blank placeholders in these parameters (ignore_changes = [value]), so the
# password never passes through Terraform or its state.
#
# Usage: scripts/set-smtp.sh [--dry-run] [--disable]
#   Reads SMTP_HOST, SMTP_PORT (default 587), SMTP_USERNAME and SMTP_PASSWORD from the
#   environment; anything missing is prompted. The password is read without echo from the
#   terminal (or stdin when piped), never from argv.
#   --disable: write the placeholders (a blank host, username and password, port 587): email off.
#   --dry-run: validate inputs and credentials, write nothing.
#   env: PROJECT (default security-app), AWS_PROFILE (default learnerlab),
#        AWS_REGION (default us-east-1), CLUSTER (default ${PROJECT}-cluster-v2)
#
# Lab provider: smtp.gmail.com, port 587 (STARTTLS), a dedicated Gmail account with 2-Step
# Verification and an App Password. Values reach aws through 0600 temp files (file://) and are
# never printed.
#
# A failed write rolls back: the previous values are read first (a missing parameter counts as
# the placeholder), and on a failed put every parameter touched so far is restored, user-service
# is not redeployed and the script exits non-zero. If a restore fails too, the parameters that
# may be inconsistent are named (never their values).
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

# SSM rejects an empty value; a single space is the "unset" placeholder (blank host = disabled).
# The port placeholder is 587, the same as Terraform seeds and user-service's default.
BLANK=" "
PORT_PLACEHOLDER="587"

if [ "$DISABLE" -eq 1 ]; then
  SMTP_HOST="$BLANK" SMTP_PORT="$PORT_PLACEHOLDER" SMTP_USERNAME="$BLANK" SMTP_PASSWORD="$BLANK"
else
  if [ -z "${SMTP_HOST:-}" ]; then
    read -r -p "SMTP host (e.g. smtp.gmail.com): " SMTP_HOST || true
  fi
  SMTP_PORT="${SMTP_PORT:-587}"
  if [ -z "${SMTP_USERNAME:-}" ]; then
    read -r -p "SMTP username (the Gmail address): " SMTP_USERNAME || true
  fi
  if [ -z "${SMTP_PASSWORD:-}" ]; then
    printf 'SMTP password (App Password, not echoed): ' >&2
    read -r -s SMTP_PASSWORD || true
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

NAMES=(host port username password)
NEW=("$SMTP_HOST" "$SMTP_PORT" "$SMTP_USERNAME" "$SMTP_PASSWORD")
OLD=()

placeholder_for() { if [ "$1" = port ]; then printf '%s' "$PORT_PLACEHOLDER"; else printf '%s' "$BLANK"; fi; }

# Prints the current value; a missing parameter prints its placeholder. Any other failure is fatal
# so nothing is written without a way back. Error output is discarded: it must not carry values.
read_current() {
  local name="$1" key="$2" out
  if out="$(awsr ssm get-parameter --name "$name" --with-decryption \
    --query Parameter.Value --output text 2>"$TMP/get.err")"; then
    printf '%s' "$out"
  elif rg -q ParameterNotFound "$TMP/get.err"; then
    placeholder_for "$key"
  else
    return 1
  fi
}

put() {
  local name="$1" value="$2" file="$TMP/value" rc=0
  printf '%s' "$value" >"$file"
  awsr ssm put-parameter --name "$name" --type SecureString --overwrite \
    --value "file://$file" >/dev/null 2>&1 || rc=$?
  rm -f "$file"
  return "$rc"
}

for i in "${!NAMES[@]}"; do
  OLD[i]="$(read_current "$PARAM_PREFIX/smtp-${NAMES[$i]}" "${NAMES[$i]}")" ||
    die "could not read the current value of smtp-${NAMES[$i]}; nothing was changed"
done

# Restores parameters 0..$1 (the failing one included: a failed put may still have applied).
rollback() {
  local last="$1" i bad=()
  for ((i = 0; i <= last; i++)); do
    put "$PARAM_PREFIX/smtp-${NAMES[$i]}" "${OLD[$i]}" || bad+=("smtp-${NAMES[$i]}")
  done
  if [ "${#bad[@]}" -gt 0 ]; then
    log "ERROR: could not restore: ${bad[*]}; they may hold inconsistent values, fix them with set-smtp.sh"
  else
    log "restored the previous values of the parameters touched so far"
  fi
}

for i in "${!NAMES[@]}"; do
  if put "$PARAM_PREFIX/smtp-${NAMES[$i]}" "${NEW[$i]}"; then
    log "updated $PARAM_PREFIX/smtp-${NAMES[$i]}"
  else
    log "ERROR: writing smtp-${NAMES[$i]} failed"
    rollback "$i"
    die "SMTP settings not changed; user-service was not redeployed"
  fi
done

# ECS reads `secrets` only when a task starts, so new tasks pick up the values.
awsr ecs update-service --cluster "$CLUSTER" --service user-service --force-new-deployment >/dev/null
if [ "$DISABLE" -eq 1 ]; then
  log "user-service redeploying with the report email disabled"
else
  log "user-service redeploying with the new SMTP settings"
fi
