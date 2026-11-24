#!/usr/bin/env bash
# Offline tests for set-smtp.sh: a fake `aws` on PATH logs argv and the content of any file://
# value it receives. Needs no credentials and no network. Values are dummies.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="$SCRIPT_DIR/set-smtp.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FAKE_PASSWORD="fake-app-password-abcd"

mkdir -p "$WORK/bin"
cat >"$WORK/bin/aws" <<'FAKE'
#!/usr/bin/env bash
# State: one file per parameter in $FAKE_AWS_STATE (name with / replaced by _). A put records the
# command in $FAKE_AWS_LOG and the value in $FAKE_AWS_PUTS as "<name>|<value>"; FAKE_PUT_FAIL=<n>
# makes the nth put (1-based) fail without storing anything (FAKE_PUT_FAIL_ALSO: a second one); FAKE_GET_FAIL=1 fails every get with
# an error other than ParameterNotFound.
echo "$*" >>"$FAKE_AWS_LOG"
name=""; file=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --name) name="$2"; shift ;;
    file://*) file="${1#file://}" ;;
  esac
  shift
done
args="$(tail -n 1 "$FAKE_AWS_LOG")"
key="$FAKE_AWS_STATE/${name//\//_}"
case "$args" in
  *"sts get-caller-identity"*) [ "${FAKE_STS_FAIL:-0}" = "1" ] && exit 254; echo "123456789012" ;;
  *"ssm get-parameter"*)
    [ "${FAKE_GET_FAIL:-0}" = "1" ] && { echo "AccessDeniedException" >&2; exit 254; }
    [ -e "$key" ] || { echo "An error occurred (ParameterNotFound)" >&2; exit 254; }
    cat "$key"; echo ;;
  *"ssm put-parameter"*)
    n=$(( $(wc -l <"$FAKE_AWS_PUTS") + 1 ))
    { printf '%s|' "$name"; cat "$file"; echo; } >>"$FAKE_AWS_PUTS"
    [ "${FAKE_PUT_FAIL:-0}" = "$n" ] && exit 254
    [ "${FAKE_PUT_FAIL_ALSO:-0}" = "$n" ] && exit 254
    cp "$file" "$key" ;;
esac
exit 0
FAKE
chmod +x "$WORK/bin/aws"

fail=0
err() { echo "FAIL: $*" >&2; fail=1; }

P=/security-app/user-service
# seed <state-dir>: previous values; tests override it. Default: nothing stored.
SEED=""
seed() { local kv; for kv in $SEED; do printf '%s' "${kv#*=}" >"$1/${P//\//_}_smtp-${kv%%=*}"; done; }
# stored <name> <param>: the value currently stored (empty output if missing)
stored() { cat "$WORK/$1.state/${P//\//_}_smtp-$2" 2>/dev/null || true; }
# puts_of <name>: the parameter names written, in order, comma separated
puts_of() { cut -d'|' -f1 "$WORK/$1.puts" | sd "^$P/smtp-" '' | paste -sd, -; }

# run <name> <stdin-file> [env...] -- [args...]
run() {
  local name="$1" input="$2"; shift 2
  local envs=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  [ "$#" -gt 0 ] && shift
  : >"$WORK/$name.aws"; : >"$WORK/$name.puts"
  rm -rf "$WORK/$name.state"; mkdir -p "$WORK/$name.state"
  seed "$WORK/$name.state"
  set +e
  env -u SMTP_HOST -u SMTP_PORT -u SMTP_USERNAME -u SMTP_PASSWORD PATH="$WORK/bin:$PATH" \
    FAKE_AWS_LOG="$WORK/$name.aws" FAKE_AWS_PUTS="$WORK/$name.puts" FAKE_AWS_STATE="$WORK/$name.state" \
    "${envs[@]}" bash "$TARGET" "$@" <"$input" \
    >"$WORK/$name.out" 2>"$WORK/$name.err"
  echo $? >"$WORK/$name.rc"
  set -e
}

no_leak() {
  local name="$1"
  rg -q -F "$FAKE_PASSWORD" "$WORK/$name.aws" && err "$name: the password leaked into aws argv"
  rg -q -F "$FAKE_PASSWORD" "$WORK/$name.out" "$WORK/$name.err" && err "$name: the password was printed"
  return 0
}

: >"$WORK/empty"

OLD_PASSWORD="old-app-password-wxyz"
OLD_HOST="old.example.test"
OLD_USER="old-user@example.test"

# expect <name> <param> <value>: the stored value of a parameter
expect() { [ "$(stored "$1" "$2")" = "$3" ] || err "$1: smtp-$2 holds '$(stored "$1" "$2")', expected '$3'"; }
# no_secrets <name>: neither the new nor the old password in argv, stdout or stderr
no_secrets() {
  local name="$1" s
  for s in "$FAKE_PASSWORD" "$OLD_PASSWORD"; do
    rg -q -F "$s" "$WORK/$name.aws" && err "$name: a password was in aws argv"
    rg -q -F "$s" "$WORK/$name.out" "$WORK/$name.err" && err "$name: a password was printed"
  done
  return 0
}
rc_is() { [ "$(cat "$WORK/$1.rc")" = "$2" ] || err "$1: exit $(cat "$WORK/$1.rc"), expected $2: $(cat "$WORK/$1.err")"; }
no_update() { rg -q 'ecs update-service' "$WORK/$1.aws" && err "$1: user-service must not be redeployed"; return 0; }

# --- values from the environment
run env "$WORK/empty" SMTP_HOST=smtp.gmail.com SMTP_USERNAME=reports@example.test SMTP_PASSWORD="$FAKE_PASSWORD" --
rc_is env 0
[ "$(puts_of env)" = "host,port,username,password" ] || err "env: wrote '$(puts_of env)'"
rg -q -- "ssm put-parameter --name /security-app/user-service/smtp-host --type SecureString --overwrite --value file://" "$WORK/env.aws" || err "env: not put as SecureString"
expect env host smtp.gmail.com
expect env port 587
expect env username reports@example.test
expect env password "$FAKE_PASSWORD"
rg -q -- "ecs update-service --cluster security-app-cluster-v2 --service user-service --force-new-deployment" "$WORK/env.aws" || err "env: user-service not redeployed"
rg -q -- "--region us-east-1" "$WORK/env.aws" || err "env: region must be explicit"
rg -q -- "--profile learnerlab" "$WORK/env.aws" || err "env: must use the learnerlab profile"
no_secrets env

# --- password from stdin (the prompt path), never from argv
printf '%s\n' "$FAKE_PASSWORD" >"$WORK/pw"
run stdin "$WORK/pw" SMTP_HOST=smtp.gmail.com SMTP_USERNAME=reports@example.test --
rc_is stdin 0
expect stdin password "$FAKE_PASSWORD"
no_secrets stdin

# --- missing password: exit 1, nothing read, written or redeployed
SEED="host=$OLD_HOST port=2525 username=$OLD_USER password=$OLD_PASSWORD"
run missing "$WORK/empty" SMTP_HOST=smtp.gmail.com SMTP_USERNAME=reports@example.test --
rc_is missing 1
grep -q 'required' "$WORK/missing.err" || err "missing: the message must say what is required"
[ -z "$(puts_of missing)" ] || err "missing: wrote '$(puts_of missing)'"
no_update missing
expect missing host "$OLD_HOST"
expect missing password "$OLD_PASSWORD"
no_secrets missing
SEED=""

# --- invalid port: no write
run badport "$WORK/empty" SMTP_HOST=h SMTP_PORT=abc SMTP_USERNAME=u SMTP_PASSWORD="$FAKE_PASSWORD" --
rc_is badport 1
[ -z "$(puts_of badport)" ] || err "badport: must not write"
no_update badport

# --- expired credentials: no write
run expired "$WORK/empty" FAKE_STS_FAIL=1 SMTP_HOST=h SMTP_USERNAME=u SMTP_PASSWORD="$FAKE_PASSWORD" --
rc_is expired 1
[ -z "$(puts_of expired)" ] || err "expired: must not write"
no_update expired

# --- dry run: validates, writes and redeploys nothing
SEED="host=$OLD_HOST port=2525 username=$OLD_USER password=$OLD_PASSWORD"
run dry "$WORK/empty" SMTP_HOST=h SMTP_USERNAME=u SMTP_PASSWORD="$FAKE_PASSWORD" -- --dry-run
rc_is dry 0
[ -z "$(puts_of dry)" ] || err "dry: must not write"
no_update dry
expect dry host "$OLD_HOST"
no_secrets dry

# --- disable: placeholders in all four (blank host, username, password; port 587), then redeploy
run disable "$WORK/empty" -- --disable
rc_is disable 0
[ "$(puts_of disable)" = "host,port,username,password" ] || err "disable: wrote '$(puts_of disable)'"
expect disable host " "
expect disable port "587"
expect disable username " "
expect disable password " "
rg -q -- "ecs update-service --cluster security-app-cluster-v2 --service user-service --force-new-deployment" "$WORK/disable.aws" || err "disable: user-service not redeployed"
no_secrets disable
SEED=""

# --- rollback: the third write fails, the first two return to their previous values
SEED="host=$OLD_HOST port=2525 username=$OLD_USER password=$OLD_PASSWORD"
run rollback "$WORK/empty" FAKE_PUT_FAIL=3 SMTP_HOST=smtp.gmail.com SMTP_USERNAME=reports@example.test SMTP_PASSWORD="$FAKE_PASSWORD" --
rc_is rollback 1
[ "$(puts_of rollback)" = "host,port,username,host,port,username" ] || err "rollback: wrote '$(puts_of rollback)'"
expect rollback host "$OLD_HOST"
expect rollback port 2525
expect rollback username "$OLD_USER"
expect rollback password "$OLD_PASSWORD"
no_update rollback
grep -q 'smtp-username' "$WORK/rollback.err" || err "rollback: the message must name the failed parameter"
no_secrets rollback

# --- rollback with a parameter that did not exist: restored to its placeholder
SEED="host=$OLD_HOST"
run missingprev "$WORK/empty" FAKE_PUT_FAIL=3 SMTP_HOST=smtp.gmail.com SMTP_USERNAME=reports@example.test SMTP_PASSWORD="$FAKE_PASSWORD" --
rc_is missingprev 1
expect missingprev host "$OLD_HOST"
expect missingprev port 587
no_update missingprev
no_secrets missingprev
SEED=""

# --- the first write fails: only it is restored
SEED="host=$OLD_HOST port=2525 username=$OLD_USER password=$OLD_PASSWORD"
run firstfail "$WORK/empty" FAKE_PUT_FAIL=1 SMTP_HOST=smtp.gmail.com SMTP_USERNAME=reports@example.test SMTP_PASSWORD="$FAKE_PASSWORD" --
rc_is firstfail 1
[ "$(puts_of firstfail)" = "host,host" ] || err "firstfail: wrote '$(puts_of firstfail)'"
expect firstfail host "$OLD_HOST"
no_update firstfail

# --- the restore fails too: exit 1 and the inconsistent parameters are named
run restorefail "$WORK/empty" FAKE_PUT_FAIL=3 FAKE_PUT_FAIL_ALSO=4 SMTP_HOST=smtp.gmail.com SMTP_USERNAME=reports@example.test SMTP_PASSWORD="$FAKE_PASSWORD" --
rc_is restorefail 1
grep -q 'could not restore: smtp-host' "$WORK/restorefail.err" || err "restorefail: must name smtp-host as inconsistent: $(cat "$WORK/restorefail.err")"
no_update restorefail
no_secrets restorefail

# --- the previous values cannot be read (not a missing parameter): nothing is written
run readfail "$WORK/empty" FAKE_GET_FAIL=1 SMTP_HOST=h SMTP_USERNAME=u SMTP_PASSWORD="$FAKE_PASSWORD" --
rc_is readfail 1
[ -z "$(puts_of readfail)" ] || err "readfail: must not write"
no_update readfail
SEED=""

if [ "$fail" -ne 0 ]; then exit 1; fi
echo "test-set-smtp: OK"
