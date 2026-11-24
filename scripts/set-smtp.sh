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
# Needs only bash, coreutils, grep and the aws CLI.
#
# Lab provider: smtp.gmail.com, port 587 (STARTTLS), a dedicated Gmail account with 2-Step
# Verification and an App Password. Values reach aws through 0600 temp files (file://) and are
# never printed.
#
# A failed write rolls back: the previous values are read first (a missing parameter counts as
# the placeholder), and on a failed put every parameter touched so far is restored, user-service
# is not redeployed and the script exits non-zero. If a restore fails too, the parameters that
# may be inconsistent are named (never their values). A failed aws call shows the first line of
# its error (the cause, e.g. AccessDenied) with every known value redacted.
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

# Prints the first line of an aws error file, with every known value replaced by <redacted>
# (literal replacement, not a regex). Blank values and the port are not secrets, so they are kept.
cause() {
  local line v i j tmp
  local -a vals=()
  IFS= read -r line <"$1" || true
  # Every new and old value except the port (looked up by name, not position), blanks skipped.
  for i in "${!NAMES[@]}"; do
    [ "${NAMES[$i]}" = port ] && continue
    for v in "${NEW[$i]-}" "${OLD[$i]-}"; do
      [ -n "${v//[[:space:]]/}" ] && vals+=("$v")
    done
  done
  # Longest first, so a value contained in another (a username inside the password) cannot
  # break up the longer one and leave part of it visible.
  for ((i = 0; i < ${#vals[@]}; i++)); do
    for ((j = i + 1; j < ${#vals[@]}; j++)); do
      if [ "${#vals[$j]}" -gt "${#vals[$i]}" ]; then
        tmp="${vals[$i]}"
        vals[i]="${vals[$j]}"
        vals[j]="$tmp"
      fi
    done
  done
  for v in ${vals[@]+"${vals[@]}"}; do
    line="${line//"$v"/<redacted>}"
  done
  printf '%s' "${line:0:300}"
}

# Prints the current value; a missing parameter prints its placeholder. Any other failure is fatal
# so nothing is written without a way back. The error goes to a file, never straight to the
# terminal: only its redacted first line is shown by the caller (see cause).
read_current() {
  local name="$1" key="$2" out
  if out="$(awsr ssm get-parameter --name "$name" --with-decryption \
    --query Parameter.Value --output text 2>"$TMP/get.err")"; then
    printf '%s' "$out"
  elif grep -q ParameterNotFound "$TMP/get.err"; then
    placeholder_for "$key"
  else
    return 1
  fi
}

put() {
  local name="$1" value="$2" file="$TMP/value" rc=0
  printf '%s' "$value" >"$file"
  awsr ssm put-parameter --name "$name" --type SecureString --overwrite \
    --value "file://$file" >/dev/null 2>"$TMP/put.err" || rc=$?
  rm -f "$file"
  return "$rc"
}

for i in "${!NAMES[@]}"; do
  # The command substitution runs in a subshell, so the error file is read here, not inside it.
  OLD[i]="$(read_current "$PARAM_PREFIX/smtp-${NAMES[$i]}" "${NAMES[$i]}")" || {
    die "could not read the current value of smtp-${NAMES[$i]}; nothing was changed ($(cause "$TMP/get.err"))"
  }
done

# Restores parameters 0..$1 (the failing one included: a failed put may still have applied).
# Returns 1 and sets UNRESTORED when some could not be restored.
UNRESTORED=""
rollback() {
  local last="$1" i bad=()
  for ((i = 0; i <= last; i++)); do
    put "$PARAM_PREFIX/smtp-${NAMES[$i]}" "${OLD[$i]}" ||
      { bad+=("smtp-${NAMES[$i]}"); log "restore of smtp-${NAMES[$i]} failed: $(cause "$TMP/put.err")"; }
  done
  if [ "${#bad[@]}" -gt 0 ]; then
    UNRESTORED="${bad[*]}"
    log "ERROR: could not restore: $UNRESTORED; they may hold inconsistent values, fix them with set-smtp.sh"
    return 1
  fi
  log "restored the previous values of the parameters touched so far"
}

for i in "${!NAMES[@]}"; do
  if put "$PARAM_PREFIX/smtp-${NAMES[$i]}" "${NEW[$i]}"; then
    log "updated $PARAM_PREFIX/smtp-${NAMES[$i]}"
  else
    log "ERROR: writing smtp-${NAMES[$i]} failed: $(cause "$TMP/put.err")"
    if rollback "$i"; then
      die "SMTP settings not changed; user-service was not redeployed"
    fi
    die "SMTP settings may be inconsistent (check: $UNRESTORED); user-service was not redeployed"
  fi
done

# ECS reads `secrets` only when a task starts, so new tasks pick up the values.
awsr ecs update-service --cluster "$CLUSTER" --service user-service --force-new-deployment >/dev/null
if [ "$DISABLE" -eq 1 ]; then
  log "user-service redeploying with the report email disabled"
else
  log "user-service redeploying with the new SMTP settings"
fi
