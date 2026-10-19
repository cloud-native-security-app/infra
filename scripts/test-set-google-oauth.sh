#!/usr/bin/env bash
# Offline tests for set-google-oauth.sh: a fake `aws` on PATH logs argv and the content of
# any file:// value it receives. Needs no credentials and no network. Values are dummies.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="$SCRIPT_DIR/set-google-oauth.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FAKE_ID="1234-fake.apps.googleusercontent.com"
FAKE_SECRET="GOCSPX-fake-client-secret"

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

# run <name> [env...] -- [args...]
run() {
  local name="$1"; shift
  local envs=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  [ "$#" -gt 0 ] && shift
  : >"$WORK/$name.aws"; : >"$WORK/$name.files"
  set +e
  env -u GOOGLE_CLIENT_ID -u GOOGLE_CLIENT_SECRET PATH="$WORK/bin:$PATH" \
    FAKE_AWS_LOG="$WORK/$name.aws" FAKE_AWS_FILES="$WORK/$name.files" \
    OAUTH_FILE="$WORK/missing.env" "${envs[@]}" bash "$TARGET" "$@" \
    >"$WORK/$name.out" 2>"$WORK/$name.err"
  echo $? >"$WORK/$name.rc"
  set -e
}

no_leak() {
  local name="$1"
  for v in "$FAKE_ID" "$FAKE_SECRET"; do
    rg -q -F "$v" "$WORK/$name.aws" && err "$name: a value leaked into aws argv"
    rg -q -F "$v" "$WORK/$name.out" "$WORK/$name.err" && err "$name: a value was printed"
  done
  return 0
}

# --- values from the environment
run env GOOGLE_CLIENT_ID="$FAKE_ID" GOOGLE_CLIENT_SECRET="$FAKE_SECRET" --
[ "$(cat "$WORK/env.rc")" = 0 ] || err "env: exit $(cat "$WORK/env.rc"): $(cat "$WORK/env.err")"
rg -q -- "ssm put-parameter --name /security-app/gateway/google-client-id --type SecureString --overwrite --value file://" "$WORK/env.aws" || err "env: client id not put as SecureString"
rg -q -- "ssm put-parameter --name /security-app/gateway/google-client-secret --type SecureString --overwrite --value file://" "$WORK/env.aws" || err "env: client secret not put as SecureString"
rg -q -F "|$FAKE_ID" "$WORK/env.files" || err "env: client id value not passed through a file"
rg -q -F "|$FAKE_SECRET" "$WORK/env.files" || err "env: client secret value not passed through a file"
rg -q -- "ecs update-service --cluster security-app-cluster-v2 --service gateway --force-new-deployment" "$WORK/env.aws" || err "env: gateway not redeployed"
rg -q -- "--region us-east-1" "$WORK/env.aws" || err "env: region must be explicit"
rg -q -- "--profile learnerlab" "$WORK/env.aws" || err "env: must use the learnerlab profile"
no_leak env
# the value files are deleted after use
while IFS='|' read -r f _; do [ -e "$f" ] && err "env: temp value file $f left behind"; done <"$WORK/env.files"

# --- values from the legacy .state file
printf 'GOOGLE_CLIENT_ID=%q\nGOOGLE_CLIENT_SECRET=%q\n' "$FAKE_ID" "$FAKE_SECRET" >"$WORK/oauth.env"
run file OAUTH_FILE="$WORK/oauth.env" --
[ "$(cat "$WORK/file.rc")" = 0 ] || err "file: exit $(cat "$WORK/file.rc"): $(cat "$WORK/file.err")"
rg -q -F "|$FAKE_SECRET" "$WORK/file.files" || err "file: values from OAUTH_FILE not used"
no_leak file

# --- missing values: no write
run missing --
[ "$(cat "$WORK/missing.rc")" != 0 ] || err "missing: must fail"
rg -q 'put-parameter' "$WORK/missing.aws" && err "missing: must not write"

# --- expired credentials: no write
run expired FAKE_STS_FAIL=1 GOOGLE_CLIENT_ID="$FAKE_ID" GOOGLE_CLIENT_SECRET="$FAKE_SECRET" --
[ "$(cat "$WORK/expired.rc")" != 0 ] || err "expired: must fail"
rg -q 'put-parameter' "$WORK/expired.aws" && err "expired: must not write"

# --- dry run: validates, writes nothing, redeploys nothing
run dry GOOGLE_CLIENT_ID="$FAKE_ID" GOOGLE_CLIENT_SECRET="$FAKE_SECRET" -- --dry-run
[ "$(cat "$WORK/dry.rc")" = 0 ] || err "dry: exit $(cat "$WORK/dry.rc")"
rg -q 'put-parameter|update-service' "$WORK/dry.aws" && err "dry: must not write"
no_leak dry

if [ "$fail" -ne 0 ]; then exit 1; fi
echo "test-set-google-oauth: OK"
