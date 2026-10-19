#!/usr/bin/env bash
# Asserts that compose and push-images.sh find the service repos as siblings
# of infra. Offline: runs no AWS command.
set -euo pipefail

INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVICES_ROOT="${SERVICES_ROOT:-$(cd "$INFRA_DIR/.." && pwd)}"
COMPOSE_FILE="$INFRA_DIR/docker-compose.yml"
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

# (b) push-images.sh resolves the service repos through SERVICES_ROOT, not the cwd.
rg -q 'SERVICES_ROOT="\$\{SERVICES_ROOT:-' "$INFRA_DIR/scripts/push-images.sh" || err "push-images.sh does not define SERVICES_ROOT overridable via env"
if rg -n '^\s*cd |\s\./(user-service|nmap-service|gateway|front|broker)' "$INFRA_DIR/scripts/push-images.sh" >&2; then
  err "push-images.sh still uses cwd-relative service paths"
fi

# (c) the sibling service repos exist.
for d in "${SERVICE_DIRS[@]}"; do
  [ -d "$SERVICES_ROOT/$d" ] || err "sibling repo dir '$SERVICES_ROOT/$d' not found"
done

if [ "$fail" -eq 0 ]; then echo "check-paths: OK"; fi
exit "$fail"
