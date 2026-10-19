#!/usr/bin/env bash
# Offline tests for push-images.sh: fake `terraform`, `aws` and `docker` on PATH log argv
# (and stdin for docker login). Needs no credentials, no network and no Docker daemon.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="$SCRIPT_DIR/push-images.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

REG="123456789012.dkr.ecr.us-east-1.amazonaws.com"
FAKE_PASSWORD="fake-ecr-login-password"
GW_URL="https://alb-test.us-east-1.elb.amazonaws.com:8080"

mkdir -p "$WORK/bin" "$WORK/services/broker/rabbitmq/tls" "$WORK/services-notls"
cat >"$WORK/outputs.json" <<JSON
{
  "ecr_repository_urls": {"value": {
    "user-service": "$REG/security-app/user-service",
    "nmap-service": "$REG/security-app/nmap-service",
    "gateway": "$REG/security-app/gateway",
    "front": "$REG/security-app/front"}},
  "gateway_public_url": {"value": "$GW_URL"},
  "cluster_name": {"value": "security-app-cluster-v2"}
}
JSON

cat >"$WORK/bin/terraform" <<'FAKE'
#!/usr/bin/env bash
echo "TF_DATA_DIR=${TF_DATA_DIR:-} $*" >>"$FAKE_TF_LOG"
if [ "${FAKE_TF_EMPTY:-0}" = "1" ]; then echo "{}"; else cat "$FAKE_TF_JSON"; fi
FAKE
cat >"$WORK/bin/aws" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >>"$FAKE_AWS_LOG"
case "$*" in
  *"sts get-caller-identity"*) [ "${FAKE_STS_FAIL:-0}" = "1" ] && { echo "ExpiredToken" >&2; exit 254; }; echo "123456789012" ;;
  *"ecr get-login-password"*) echo "fake-ecr-login-password" ;;
esac
exit 0
FAKE
cat >"$WORK/bin/docker" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >>"$FAKE_DOCKER_LOG"
case "$1" in
  login) { printf '%s|' "$*"; cat; echo; } >>"$FAKE_DOCKER_STDIN" ;;
esac
exit 0
FAKE
chmod +x "$WORK/bin/terraform" "$WORK/bin/aws" "$WORK/bin/docker"

fail=0
err() { echo "FAIL: $*" >&2; fail=1; }

# run <name> [env...] -- [args...]: runs the script, stores stdout/stderr/rc under $WORK/<name>.
run() {
  local name="$1"; shift
  local envs=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  [ "$#" -gt 0 ] && shift
  : >"$WORK/$name.aws"; : >"$WORK/$name.docker"; : >"$WORK/$name.stdin"; : >"$WORK/$name.tf"
  set +e
  env PATH="$WORK/bin:$PATH" FAKE_AWS_LOG="$WORK/$name.aws" FAKE_DOCKER_LOG="$WORK/$name.docker" \
    FAKE_DOCKER_STDIN="$WORK/$name.stdin" FAKE_TF_LOG="$WORK/$name.tf" FAKE_TF_JSON="$WORK/outputs.json" \
    SERVICES_ROOT="$WORK/services" "${envs[@]}" bash "$TARGET" "$@" \
    >"$WORK/$name.out" 2>"$WORK/$name.err"
  echo $? >"$WORK/$name.rc"
  set -e
}
rc() { cat "$WORK/$1.rc"; }

# --- happy path: all four services built, pushed and redeployed
run ok --
[ "$(rc ok)" = 0 ] || err "ok: exit $(rc ok): $(cat "$WORK/ok.err")"
for svc in user-service nmap-service gateway front; do
  rg -q -F -- "-t $REG/security-app/$svc:latest $WORK/services/$svc" "$WORK/ok.docker" || err "ok: $svc not built from SERVICES_ROOT with :latest"
  rg -q -x -F "push $REG/security-app/$svc:latest" "$WORK/ok.docker" || err "ok: $svc not pushed"
  rg -q -F "ecs update-service --cluster security-app-cluster-v2 --service $svc --force-new-deployment" "$WORK/ok.aws" || err "ok: $svc not redeployed"
done
[ "$(rg -c '^build ' "$WORK/ok.docker")" = 4 ] || err "ok: expected 4 builds"
rg -q -- "--profile learnerlab.*us-east-1.*sts get-caller-identity" "$WORK/ok.aws" || err "ok: STS check must pass profile and region"
rg -q -F -- "-chdir=" "$WORK/ok.tf" || err "ok: terraform must be called with -chdir"
rg -q -F "output -json" "$WORK/ok.tf" || err "ok: terraform output -json not used"
# every aws call carries profile and region (aws-cli v1 ignores AWS_REGION)
while IFS= read -r line; do
  case "$line" in *"--profile learnerlab"*"--region us-east-1"*|*"--region us-east-1"*"--profile learnerlab"*) ;; *) err "ok: aws call without profile+region: $line" ;; esac
done <"$WORK/ok.aws"

# --- front gets the gateway URL as build arg
rg -F -- "--build-arg VITE_GATEWAY_BASE_URL=$GW_URL" "$WORK/ok.docker" | rg -q "/front:latest" || err "ok: front build arg missing"
[ "$(rg -c -F 'VITE_GATEWAY_BASE_URL' "$WORK/ok.docker")" = 1 ] || err "ok: build arg must be on front only"

# --- nmap tls build context only when the directory exists
rg -F -- "--build-context tls=$WORK/services/broker/rabbitmq/tls" "$WORK/ok.docker" | rg -q "nmap-service:latest" || err "ok: nmap tls build context missing"
[ "$(rg -c -F 'build-context' "$WORK/ok.docker")" = 1 ] || err "ok: tls context must be on nmap only"
run notls SERVICES_ROOT="$WORK/services-notls" -- nmap-service
[ "$(rc notls)" = 0 ] || err "notls: exit $(rc notls)"
rg -q -F 'build-context' "$WORK/notls.docker" && err "notls: tls context passed although the directory is missing"

# --- ECR login: password on stdin only, never argv, never printed
rg -q -F "ecr get-login-password" "$WORK/ok.aws" || err "ok: ecr get-login-password not called"
rg -q -F -- "login --username AWS --password-stdin $REG|$FAKE_PASSWORD" "$WORK/ok.stdin" || err "ok: login must use the registry host and the password on stdin"
rg -q -F "$FAKE_PASSWORD" "$WORK/ok.docker" "$WORK/ok.aws" "$WORK/ok.out" "$WORK/ok.err" && err "ok: ECR password leaked into argv or output"

# --- subset selection
run subset -- gateway front
[ "$(rc subset)" = 0 ] || err "subset: exit $(rc subset)"
[ "$(rg -c '^build ' "$WORK/subset.docker")" = 2 ] || err "subset: expected 2 builds"
rg -q "user-service|nmap-service" "$WORK/subset.docker" "$WORK/subset.aws" && err "subset: unselected service touched"
[ "$(rg -c -F 'update-service' "$WORK/subset.aws")" = 2 ] || err "subset: expected 2 redeploys"
run unknown -- bogus
[ "$(rc unknown)" != 0 ] || err "unknown: unknown service must fail"
rg -q '^(build|push|login)' "$WORK/unknown.docker" && err "unknown: no docker call allowed"

# --- expired credentials abort before any docker call
run expired FAKE_STS_FAIL=1 --
[ "$(rc expired)" != 0 ] || err "expired: must fail"
[ ! -s "$WORK/expired.docker" ] || err "expired: no docker call allowed"
rg -q -i 'expired|refresh' "$WORK/expired.err" || err "expired: must tell the user to refresh the lab credentials"

# --- stack not applied: no ecr_repository_urls
run empty FAKE_TF_EMPTY=1 --
[ "$(rc empty)" != 0 ] || err "empty: must fail"
[ ! -s "$WORK/empty.docker" ] || err "empty: no docker call allowed"
rg -q -i 'terraform apply|applied' "$WORK/empty.err" || err "empty: must say the stack is not applied"

# --- dry run: plans only
run dry -- --dry-run
[ "$(rc dry)" = 0 ] || err "dry: exit $(rc dry): $(cat "$WORK/dry.err")"
[ ! -s "$WORK/dry.docker" ] || err "dry: must not run docker"
rg -q 'update-service|ecr get-login-password' "$WORK/dry.aws" && err "dry: must not run aws mutations or login"
rg -q -F "$REG/security-app/front:latest" "$WORK/dry.out" "$WORK/dry.err" || err "dry: must print the planned commands"

# --- --no-redeploy
run noredeploy -- --no-redeploy
[ "$(rc noredeploy)" = 0 ] || err "noredeploy: exit $(rc noredeploy)"
rg -q -F 'update-service' "$WORK/noredeploy.aws" && err "noredeploy: must not redeploy"
[ "$(rg -c '^push ' "$WORK/noredeploy.docker")" = 4 ] || err "noredeploy: images must still be pushed"

# --- overrides and TF_DATA_DIR pass-through
run override AWS_PROFILE=other AWS_REGION=us-west-2 TF_DATA_DIR=/tmp/custom-tf -- user-service
[ "$(rc override)" = 0 ] || err "override: exit $(rc override)"
rg -q -F -- "--profile other --region us-west-2" "$WORK/override.aws" || err "override: profile/region ignored"
rg -q -F "TF_DATA_DIR=/tmp/custom-tf" "$WORK/override.tf" || err "override: TF_DATA_DIR not respected"

if [ "$fail" -ne 0 ]; then exit 1; fi
echo "test-push-images: OK"
