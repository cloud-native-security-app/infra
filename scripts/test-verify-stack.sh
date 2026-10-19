#!/usr/bin/env bash
# Offline tests for verify-stack.sh: fake `terraform`, `aws` and `curl` on PATH log argv.
# Needs no credentials and no network.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="$SCRIPT_DIR/verify-stack.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

GW="https://alb-test.us-east-1.elb.amazonaws.com:8080"
FRONT="https://alb-test.us-east-1.elb.amazonaws.com"
SERVICES="gateway front mongo nmap-service postgres user-service"

mkdir -p "$WORK/bin"
cat >"$WORK/outputs.json" <<JSON
{
  "alb_dns": {"value": "alb-test.us-east-1.elb.amazonaws.com"},
  "gateway_public_url": {"value": "$GW"},
  "front_public_url": {"value": "$FRONT"},
  "cluster_name": {"value": "security-app-cluster-v2"},
  "service_names": {"value": ["gateway","front","mongo","nmap-service","postgres","user-service"]}
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
  *"ecs describe-services"*)
    # name status running desired (tab separated, as --output text prints it)
    for s in gateway front mongo nmap-service postgres user-service; do
      run=1
      [ "${FAKE_ECS_BAD:-}" = "$s" ] && run=0
      [ "${FAKE_ECS_MISSING:-}" = "$s" ] && continue
      printf '%s\tACTIVE\t%s\t1\n' "$s" "$run"
    done ;;
esac
exit 0
FAKE
cat >"$WORK/bin/curl" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >>"$FAKE_CURL_LOG"
url="${*: -1}"
code=200
case "$url" in
  */auth/login) code="${FAKE_LOGIN_CODE:-302}" ;;
  */health) code="${FAKE_HEALTH_CODE:-200}" ;;
esac
printf '%s' "$code"
FAKE
chmod +x "$WORK/bin/terraform" "$WORK/bin/aws" "$WORK/bin/curl"

fail=0
err() { echo "FAIL: $*" >&2; fail=1; }

# run <name> [env...]: runs the script, stores stdout/stderr/rc under $WORK/<name>.
run() {
  local name="$1"; shift
  : >"$WORK/$name.aws"; : >"$WORK/$name.curl"; : >"$WORK/$name.tf"
  set +e
  env PATH="$WORK/bin:$PATH" FAKE_AWS_LOG="$WORK/$name.aws" FAKE_CURL_LOG="$WORK/$name.curl" \
    FAKE_TF_LOG="$WORK/$name.tf" FAKE_TF_JSON="$WORK/outputs.json" "$@" bash "$TARGET" \
    >"$WORK/$name.out" 2>"$WORK/$name.err"
  echo $? >"$WORK/$name.rc"
  set -e
}
rc() { cat "$WORK/$1.rc"; }

# --- all good
run ok
[ "$(rc ok)" = 0 ] || err "ok: exit $(rc ok): $(cat "$WORK/ok.out") $(cat "$WORK/ok.err")"
rg -q -F "[FAIL]" "$WORK/ok.out" && err "ok: unexpected FAIL line"
[ "$(rg -c -F '[OK]' "$WORK/ok.out")" -ge 4 ] || err "ok: expected at least 4 OK lines"
for u in "$GW/health" "$GW/api/openapi.json" "$GW/auth/login" "$FRONT/"; do
  rg -q -x -F -- "-sk -o /dev/null -w %{http_code} --max-time 10 $u" "$WORK/ok.curl" || err "ok: curl for $u must use -sk, -w and --max-time 10"
done
[ "$(rg -c . "$WORK/ok.curl")" = 4 ] || err "ok: expected exactly 4 curl calls"
rg -q -F -- "-chdir=" "$WORK/ok.tf" || err "ok: terraform must be called with -chdir"
rg -q -F "output -json" "$WORK/ok.tf" || err "ok: terraform output -json not used"
rg -q -- "--profile learnerlab" "$WORK/ok.aws" || err "ok: profile missing"
rg -q -- "--region us-east-1" "$WORK/ok.aws" || err "ok: region missing"
for s in $SERVICES; do
  rg -q -F -- "$s" <(rg "describe-services" "$WORK/ok.aws") || err "ok: service $s not queried"
done
rg -q -F -- "--cluster security-app-cluster-v2" "$WORK/ok.aws" || err "ok: cluster not passed"

# --- login not a redirect
run login FAKE_LOGIN_CODE=500
[ "$(rc login)" = 1 ] || err "login: must exit 1, got $(rc login)"
rg -q '^\[FAIL\] .*login' "$WORK/login.out" || err "login: expected a FAIL line for the login check"

# --- health down
run health FAKE_HEALTH_CODE=503
[ "$(rc health)" = 1 ] || err "health: must exit 1"
rg -q '^\[FAIL\] .*health.*503' "$WORK/health.out" || err "health: FAIL line must show the status code"

# --- service with running != desired
run bad FAKE_ECS_BAD=gateway
[ "$(rc bad)" = 1 ] || err "bad: must exit 1"
rg -q '^\[FAIL\] .*gateway' "$WORK/bad.out" || err "bad: expected a FAIL line for gateway"
rg -q '^\[FAIL\] .*front' "$WORK/bad.out" && err "bad: healthy service flagged"
rg -q -i 'filter-log-events' "$WORK/bad.out" "$WORK/bad.err" || err "bad: expected troubleshooting hints"
rg -q -i 'rabbit|amqps' "$WORK/bad.out" "$WORK/bad.err" && err "bad: obsolete RabbitMQ hint"

# --- service missing from describe-services
run missing FAKE_ECS_MISSING=mongo
[ "$(rc missing)" = 1 ] || err "missing: must exit 1"
rg -q '^\[FAIL\] .*mongo' "$WORK/missing.out" || err "missing: expected a FAIL line for mongo"

# --- expired credentials abort before any check
run expired FAKE_STS_FAIL=1
[ "$(rc expired)" != 0 ] || err "expired: must fail"
[ ! -s "$WORK/expired.curl" ] || err "expired: no curl allowed"
rg -q -i 'expired|refresh' "$WORK/expired.err" || err "expired: must tell the user to refresh the lab credentials"

# --- stack not applied
run empty FAKE_TF_EMPTY=1
[ "$(rc empty)" != 0 ] || err "empty: must fail"
[ ! -s "$WORK/empty.curl" ] || err "empty: no curl allowed"
rg -q -i 'terraform apply|applied' "$WORK/empty.err" || err "empty: must say the stack is not applied"

if [ "$fail" -ne 0 ]; then exit 1; fi
echo "test-verify-stack: OK"
