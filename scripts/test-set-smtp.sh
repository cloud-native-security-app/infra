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
echo "$*" >>"$FAKE_AWS_LOG"
for a in "$@"; do
  case "$a" in
    file://*) f="${a#file://}"; { printf '%s|' "$f"; cat "$f"; echo; } >>"$FAKE_AWS_FILES" ;;
  esac
done
case "$*" in
  *"sts get-caller-identity"*) [ "${FAKE_STS_FAIL:-0}" = "1" ] && exit 254; echo "123456789012" ;;
esac
exit 0
FAKE
chmod +x "$WORK/bin/aws"

fail=0
err() { echo "FAIL: $*" >&2; fail=1; }

# run <name> <stdin-file> [env...] -- [args...]
run() {
  local name="$1" input="$2"; shift 2
  local envs=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  [ "$#" -gt 0 ] && shift
  : >"$WORK/$name.aws"; : >"$WORK/$name.files"
  set +e
  env -u SMTP_HOST -u SMTP_PORT -u SMTP_USERNAME -u SMTP_PASSWORD PATH="$WORK/bin:$PATH" \
    FAKE_AWS_LOG="$WORK/$name.aws" FAKE_AWS_FILES="$WORK/$name.files" \
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

# --- values from the environment
run env "$WORK/empty" SMTP_HOST=smtp.gmail.com SMTP_USERNAME=reports@example.test SMTP_PASSWORD="$FAKE_PASSWORD" --
[ "$(cat "$WORK/env.rc")" = 0 ] || err "env: exit $(cat "$WORK/env.rc"): $(cat "$WORK/env.err")"
for p in smtp-host smtp-port smtp-username smtp-password; do
  rg -q -- "ssm put-parameter --name /security-app/user-service/$p --type SecureString --overwrite --value file://" "$WORK/env.aws" || err "env: $p not put as SecureString"
done
rg -q -F "|smtp.gmail.com" "$WORK/env.files" || err "env: host not passed through a file"
rg -q -F "|587" "$WORK/env.files" || err "env: port must default to 587"
rg -q -F "|$FAKE_PASSWORD" "$WORK/env.files" || err "env: password not passed through a file"
rg -q -- "ecs update-service --cluster security-app-cluster-v2 --service user-service --force-new-deployment" "$WORK/env.aws" || err "env: user-service not redeployed"
rg -q -- "--region us-east-1" "$WORK/env.aws" || err "env: region must be explicit"
rg -q -- "--profile learnerlab" "$WORK/env.aws" || err "env: must use the learnerlab profile"
no_leak env
while IFS='|' read -r f _; do [ -e "$f" ] && err "env: temp value file $f left behind"; done <"$WORK/env.files"

# --- password from stdin (the prompt path), never from argv
printf '%s\n' "$FAKE_PASSWORD" >"$WORK/pw"
run stdin "$WORK/pw" SMTP_HOST=smtp.gmail.com SMTP_USERNAME=reports@example.test --
[ "$(cat "$WORK/stdin.rc")" = 0 ] || err "stdin: exit $(cat "$WORK/stdin.rc"): $(cat "$WORK/stdin.err")"
rg -q -F "|$FAKE_PASSWORD" "$WORK/stdin.files" || err "stdin: password from stdin not used"
no_leak stdin

# --- missing password: no write
run missing "$WORK/empty" SMTP_HOST=smtp.gmail.com SMTP_USERNAME=reports@example.test --
[ "$(cat "$WORK/missing.rc")" != 0 ] || err "missing: must fail"
rg -q 'put-parameter' "$WORK/missing.aws" && err "missing: must not write"

# --- invalid port: no write
run badport "$WORK/empty" SMTP_HOST=h SMTP_PORT=abc SMTP_USERNAME=u SMTP_PASSWORD="$FAKE_PASSWORD" --
[ "$(cat "$WORK/badport.rc")" != 0 ] || err "badport: must fail"
rg -q 'put-parameter' "$WORK/badport.aws" && err "badport: must not write"

# --- expired credentials: no write
run expired "$WORK/empty" FAKE_STS_FAIL=1 SMTP_HOST=h SMTP_USERNAME=u SMTP_PASSWORD="$FAKE_PASSWORD" --
[ "$(cat "$WORK/expired.rc")" != 0 ] || err "expired: must fail"
rg -q 'put-parameter' "$WORK/expired.aws" && err "expired: must not write"

# --- dry run: validates, writes nothing, redeploys nothing
run dry "$WORK/empty" SMTP_HOST=h SMTP_USERNAME=u SMTP_PASSWORD="$FAKE_PASSWORD" -- --dry-run
[ "$(cat "$WORK/dry.rc")" = 0 ] || err "dry: exit $(cat "$WORK/dry.rc")"
rg -q 'put-parameter|update-service' "$WORK/dry.aws" && err "dry: must not write"
no_leak dry

# --- disable: writes the blank placeholder to all four and redeploys
run disable "$WORK/empty" -- --disable
[ "$(cat "$WORK/disable.rc")" = 0 ] || err "disable: exit $(cat "$WORK/disable.rc"): $(cat "$WORK/disable.err")"
[ "$(rg -c 'put-parameter' "$WORK/disable.aws")" = 4 ] || err "disable: must write four parameters"
rg -q -x '[^|]*\| ' "$WORK/disable.files" || err "disable: blank placeholder (one space) not written"
rg -q -- "update-service .*--service user-service" "$WORK/disable.aws" || err "disable: user-service not redeployed"

if [ "$fail" -ne 0 ]; then exit 1; fi
echo "test-set-smtp: OK"
