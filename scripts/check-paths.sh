#!/usr/bin/env bash
# Asserts that compose and deploy scripts find the service repos as siblings
# of infra. Offline: runs no AWS command and sources no deploy script.
set -euo pipefail

INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVICES_ROOT="${SERVICES_ROOT:-$(cd "$INFRA_DIR/.." && pwd)}"
COMPOSE_FILE="$INFRA_DIR/docker-compose.yml"
SCRIPTS_DIR="$INFRA_DIR/deploy/aws"
BUILD_SCRIPTS=(05-build-push-core-images.sh 07-build-push-front-image.sh 17-rebuild-front-https.sh)
SERVICE_DIRS=(user-service nmap-service gateway front broker/rabbitmq)

fail=0
err() { echo "FAIL: $*" >&2; fail=1; }

# (a) compose: contexts, additional contexts and Dockerfiles exist.
if docker compose version >/dev/null 2>&1; then
  cfg="$(docker compose -f "$COMPOSE_FILE" --project-directory "$INFRA_DIR" config --format json 2>/dev/null || true)"
else
  cfg=""
fi
if [ -n "$cfg" ] && command -v jq >/dev/null 2>&1; then
  while IFS=$'\t' read -r svc ctx dockerfile; do
    [ -d "$ctx" ] || err "compose service '$svc': build.context '$ctx' is not a directory"
    [ -f "$ctx/${dockerfile:-Dockerfile}" ] || err "compose service '$svc': Dockerfile '$ctx/${dockerfile:-Dockerfile}' not found"
  done < <(jq -r '.services | to_entries[] | select(.value.build) | [.key, .value.build.context, (.value.build.dockerfile // "")] | @tsv' <<<"$cfg")
  while IFS=$'\t' read -r svc name path; do
    [ -d "$path" ] || err "compose service '$svc': additional_contexts.$name '$path' is not a directory"
  done < <(jq -r '.services | to_entries[] | .key as $k | (.value.build.additional_contexts // {}) | to_entries[] | [$k, .key, .value] | @tsv' <<<"$cfg")
  # Bind mounts of repo files must also resolve.
  while IFS=$'\t' read -r svc src; do
    [ -e "$src" ] || err "compose service '$svc': bind mount source '$src' does not exist"
  done < <(jq -r '.services | to_entries[] | .key as $k | (.value.volumes // [])[] | select(.type=="bind") | [$k, .source] | @tsv' <<<"$cfg")
else
  # Conservative fallback: relative paths in context/additional_contexts/volumes.
  while read -r p; do
    [ -e "$INFRA_DIR/$p" ] || err "compose path '$p' does not resolve from $INFRA_DIR"
  done < <(rg -o --no-line-number '(?:context:|build:|tls:|^\s*-)\s*"?(\.{1,2}/[^:"\s]+)' -r '$1' "$COMPOSE_FILE")
fi

# (b) no REPO_ROOT left in the deploy scripts.
if rg -n 'REPO_ROOT' "$SCRIPTS_DIR" --glob '*.sh' >&2; then
  err "REPO_ROOT is still referenced under deploy/aws/"
fi

# (c) build scripts use SERVICES_ROOT and the sibling repos exist.
for d in "${SERVICE_DIRS[@]}"; do
  [ -d "$SERVICES_ROOT/$d" ] || err "sibling repo dir '$SERVICES_ROOT/$d' not found"
done
rg -q '^export SERVICES_ROOT="\$\{SERVICES_ROOT:-' "$SCRIPTS_DIR/00-env.sh" || err "00-env.sh does not define SERVICES_ROOT overridable via env"
for s in "${BUILD_SCRIPTS[@]}"; do
  rg -q 'SERVICES_ROOT' "$SCRIPTS_DIR/$s" || err "$s does not use SERVICES_ROOT"
  if rg -n '^\s*cd |\s\./(user-service|nmap-service|gateway|front|broker)' "$SCRIPTS_DIR/$s" >&2; then
    err "$s still uses cwd-relative service paths"
  fi
done

if [ "$fail" -eq 0 ]; then echo "check-paths: OK"; fi
exit "$fail"
