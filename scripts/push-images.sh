#!/usr/bin/env bash
# Builds the service images, pushes them to the ECR repositories created by Terraform and
# forces an ECS redeploy so the running services pick up :latest, until each service
# repo has its own CI. Replaces the former imperative build/push scripts.
#
# Usage: scripts/push-images.sh [--dry-run] [--no-redeploy] [service...]
#   service: any of user-service nmap-service gateway front (default: all four)
#   env: AWS_PROFILE (default learnerlab), AWS_REGION (default us-east-1),
#        SERVICES_ROOT (default: parent directory of this repo; holds the service repos)
#        TF_DATA_DIR is honored by terraform if the caller sets it.
#   --dry-run:     validate credentials and outputs, print the commands, change nothing.
#   --no-redeploy: push only, skip `ecs update-service --force-new-deployment`.
#
# Terraform outputs used: ecr_repository_urls, gateway_public_url, cluster_name.
# The ECR password goes to `docker login` on stdin, never in argv, and is never printed.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AWS_PROFILE="${AWS_PROFILE:-learnerlab}"
AWS_REGION="${AWS_REGION:-us-east-1}"
SERVICES_ROOT="${SERVICES_ROOT:-$(cd "$REPO_ROOT/.." && pwd)}"
ALL_SERVICES="user-service nmap-service gateway front"
DRY_RUN=0
REDEPLOY=1
SELECTED=()

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --no-redeploy) REDEPLOY=0 ;;
    -*) echo "unknown argument: $arg" >&2; exit 2 ;;
    *) SELECTED+=("$arg") ;;
  esac
done
[ "${#SELECTED[@]}" -gt 0 ] || read -r -a SELECTED <<<"$ALL_SERVICES"

log() { echo "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

for svc in "${SELECTED[@]}"; do
  case " $ALL_SERVICES " in *" $svc "*) ;; *) die "unknown service '$svc' (valid: $ALL_SERVICES)" ;; esac
done

# aws-cli v1 ignores AWS_REGION, so profile and region are always explicit.
awsr() { aws --profile "$AWS_PROFILE" --region "$AWS_REGION" "$@"; }
tf_outputs() { terraform -chdir="$REPO_ROOT/terraform" output -json; }

if ! awsr sts get-caller-identity --query Account --output text >/dev/null 2>&1; then
  die "credentials in profile '$AWS_PROFILE' are invalid or expired; refresh the Learner Lab credentials (AWS Details -> AWS CLI) into ~/.aws/credentials"
fi

OUTPUTS="$(tf_outputs)" || die "terraform output failed; run 'terraform init' in terraform/ first"
out() { jq -r "$1" <<<"$OUTPUTS"; }
[ "$(out '(.ecr_repository_urls.value // {}) | length')" -gt 0 ] \
  || die "terraform has no ecr_repository_urls output; the stack is not applied yet (run 'terraform apply' in terraform/)"
GATEWAY_URL="$(out '.gateway_public_url.value // empty')"
CLUSTER="$(out '.cluster_name.value // empty')"

# run: executes a command, or only prints it under --dry-run.
run() {
  if [ "$DRY_RUN" -eq 1 ]; then log "DRY-RUN: $*"; else "$@"; fi
}

# Docker login needs the registry host: the repository URL up to the first '/'.
first_url="$(out ".ecr_repository_urls.value[\"${SELECTED[0]}\"] // empty")"
[ -n "$first_url" ] || die "no ECR URL for '${SELECTED[0]}' in terraform outputs"
REGISTRY="${first_url%%/*}"
if [ "$DRY_RUN" -eq 1 ]; then
  log "DRY-RUN: aws ecr get-login-password | docker login --username AWS --password-stdin $REGISTRY"
else
  awsr ecr get-login-password | docker login --username AWS --password-stdin "$REGISTRY" >/dev/null
fi

for svc in "${SELECTED[@]}"; do
  url="$(out ".ecr_repository_urls.value[\"$svc\"] // empty")"
  [ -n "$url" ] || die "no ECR URL for '$svc' in terraform outputs"
  build=(docker build)
  case "$svc" in
    front)
      [ -n "$GATEWAY_URL" ] || die "terraform has no gateway_public_url output"
      # Vite bakes the gateway URL into the bundle and the nginx CSP at build time.
      build+=(--build-arg "VITE_GATEWAY_BASE_URL=$GATEWAY_URL") ;;
    nmap-service)
      # The Dockerfile still bakes the lab RabbitMQ CA from this extra context.
      # Drop once MSG-NM removes the CA.
      if [ -d "$SERVICES_ROOT/broker/rabbitmq/tls" ]; then
        build+=(--build-context "tls=$SERVICES_ROOT/broker/rabbitmq/tls")
      fi ;;
  esac
  build+=(-t "$url:latest" "$SERVICES_ROOT/$svc")
  run "${build[@]}"
  run docker push "$url:latest"
done

if [ "$REDEPLOY" -eq 1 ]; then
  [ -n "$CLUSTER" ] || die "terraform has no cluster_name output"
  for svc in "${SELECTED[@]}"; do
    run aws ecs update-service --cluster "$CLUSTER" --service "$svc" --force-new-deployment \
      --profile "$AWS_PROFILE" --region "$AWS_REGION" --output text --query 'service.serviceName'
  done
fi

if [ "$DRY_RUN" -eq 1 ]; then log "dry run: nothing was changed"; else log "pushed: ${SELECTED[*]}"; fi
