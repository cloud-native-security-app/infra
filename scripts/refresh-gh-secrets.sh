#!/usr/bin/env bash
# Copies the temporary AWS Academy Learner Lab credentials into GitHub Actions secrets of
# the service repos, so their deploy workflows can reach AWS (the lab cannot create the IAM
# role that GitHub OIDC would need). Run it after every lab start, before deploying.
#
# Usage: scripts/refresh-gh-secrets.sh [--dry-run]
#   env: AWS_PROFILE (default learnerlab), AWS_REGION (default us-east-1),
#        GH_OWNER (default cloud-native-security-app),
#        REPOS (default "user-service nmap-service gateway front")
#   --dry-run: validate credentials and gh auth, list the targets, write nothing.
#
# Sets secrets AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_SESSION_TOKEN and the
# variable AWS_REGION on each repo. Values go to gh on stdin, never in argv (visible in
# `ps`), and are never printed.
set -euo pipefail

AWS_PROFILE="${AWS_PROFILE:-learnerlab}"
AWS_REGION="${AWS_REGION:-us-east-1}"
GH_OWNER="${GH_OWNER:-cloud-native-security-app}"
REPOS="${REPOS:-user-service nmap-service gateway front}"
DRY_RUN=0

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

log() { echo "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

cred() {
  aws configure get "$1" --profile "$AWS_PROFILE" 2>/dev/null || true
}

# Validate first: an expired lab session must not overwrite working secrets with dead ones.
# aws-cli v1 ignores AWS_REGION, so the region is always explicit.
if ! aws sts get-caller-identity --profile "$AWS_PROFILE" --region "$AWS_REGION" \
    --query Account --output text >/dev/null 2>&1; then
  die "credentials in profile '$AWS_PROFILE' are invalid or expired; refresh them from the Learner Lab (AWS Details -> AWS CLI) into ~/.aws/credentials"
fi

KEY_ID="$(cred aws_access_key_id)"
SECRET_KEY="$(cred aws_secret_access_key)"
SESSION_TOKEN="$(cred aws_session_token)"
[ -n "$KEY_ID" ] && [ -n "$SECRET_KEY" ] || die "profile '$AWS_PROFILE' has no access key"
# Lab credentials are always temporary; a missing token means the wrong profile.
[ -n "$SESSION_TOKEN" ] || die "profile '$AWS_PROFILE' has no session token; these are not Learner Lab credentials"

gh auth status >/dev/null 2>&1 || die "gh is not authenticated; run 'gh auth login'"

for repo in $REPOS; do
  target="$GH_OWNER/$repo"
  if [ "$DRY_RUN" -eq 1 ]; then
    log "DRY-RUN: would set AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_SESSION_TOKEN and AWS_REGION on $target"
    continue
  fi
  printf '%s' "$KEY_ID" | gh secret set AWS_ACCESS_KEY_ID --repo "$target"
  printf '%s' "$SECRET_KEY" | gh secret set AWS_SECRET_ACCESS_KEY --repo "$target"
  printf '%s' "$SESSION_TOKEN" | gh secret set AWS_SESSION_TOKEN --repo "$target"
  printf '%s' "$AWS_REGION" | gh variable set AWS_REGION --repo "$target"
  log "updated $target"
done
