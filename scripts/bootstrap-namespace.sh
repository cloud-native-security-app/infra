#!/usr/bin/env bash
# Idempotent bootstrap of the Cloud Map HTTP namespace (AWS CLI, no Terraform).
# AWS Academy Learner Lab denies servicediscovery:CreateHttpNamespace to the student
# role, but ECS can create the namespace itself when create-cluster receives
# --service-connect-defaults namespace=<name>. This script creates a throwaway cluster
# for that, waits until the namespace is listable, then deletes the throwaway cluster
# (deleting a cluster does not delete its namespace). Terraform reads the namespace
# with a data source and manages the real cluster.
#
# Usage: NAMESPACE_ARN="$(scripts/bootstrap-namespace.sh | tail -1)"
#   env: PROJECT (default security-app), AWS_REGION (default us-east-1), AWS_PROFILE,
#        SLEEP_SECONDS (default 3, poll and retry interval)
#   --dry-run: print the planned AWS CLI commands, execute no mutating call.
# Never deletes the namespace.
set -euo pipefail

PROJECT="${PROJECT:-security-app}"
AWS_REGION="${AWS_REGION:-us-east-1}"
SLEEP_SECONDS="${SLEEP_SECONDS:-3}"
NAMESPACE_NAME="${PROJECT}.local"
CLUSTER_NAME="${PROJECT}-ns-bootstrap"
CREATE_ATTEMPTS=5
POLL_ATTEMPTS=20
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

namespace_arn() {
  local arn
  arn="$(awsr servicediscovery list-namespaces \
    --query "Namespaces[?Name=='${NAMESPACE_NAME}'].Arn | [0]" --output text)"
  if [ "$arn" = "None" ]; then arn=""; fi
  echo "$arn"
}

ARN="$(namespace_arn)"
if [ -n "$ARN" ]; then
  log "namespace $NAMESPACE_NAME exists; nothing to do"
  echo "$ARN"
  exit 0
fi

log "namespace $NAMESPACE_NAME missing; ECS will create it through a throwaway cluster"
if [ "$DRY_RUN" -eq 1 ]; then
  log "DRY-RUN: aws --region $AWS_REGION ecs create-cluster --cluster-name $CLUSTER_NAME --service-connect-defaults namespace=$NAMESPACE_NAME"
  log "DRY-RUN: aws --region $AWS_REGION servicediscovery list-namespaces (poll up to $POLL_ATTEMPTS x ${SLEEP_SECONDS}s)"
  log "DRY-RUN: aws --region $AWS_REGION ecs delete-cluster --cluster $CLUSTER_NAME"
  exit 0
fi

CREATED=0
cleanup() {
  local rc=$?
  if [ "$CREATED" -eq 1 ]; then
    log "deleting throwaway cluster $CLUSTER_NAME (the namespace is kept)"
    awsr ecs delete-cluster --cluster "$CLUSTER_NAME" >/dev/null ||
      log "WARNING: could not delete cluster $CLUSTER_NAME; delete it manually"
  fi
  exit "$rc"
}
trap cleanup EXIT

# The first create-cluster in a fresh lab can fail until the ECS service-linked role exists.
attempt=1
while :; do
  if out="$(awsr ecs create-cluster --cluster-name "$CLUSTER_NAME" \
    --service-connect-defaults "namespace=$NAMESPACE_NAME" 2>&1)"; then
    CREATED=1
    break
  fi
  case "$out" in
    *"service linked role"* | *"service-linked role"*) ;;
    *) die "create-cluster failed: $out" ;;
  esac
  [ "$attempt" -lt "$CREATE_ATTEMPTS" ] || die "create-cluster still failing after $CREATE_ATTEMPTS attempts: $out"
  log "service-linked role not ready (attempt $attempt/$CREATE_ATTEMPTS); retrying in ${SLEEP_SECONDS}s"
  attempt=$((attempt + 1))
  sleep "$SLEEP_SECONDS"
done

for ((i = 1; i <= POLL_ATTEMPTS; i++)); do
  ARN="$(namespace_arn)"
  [ -z "$ARN" ] || break
  sleep "$SLEEP_SECONDS"
done
[ -n "$ARN" ] || die "namespace $NAMESPACE_NAME did not appear after $POLL_ATTEMPTS polls of ${SLEEP_SECONDS}s"

log "namespace $NAMESPACE_NAME created"
echo "$ARN"
