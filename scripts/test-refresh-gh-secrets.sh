#!/usr/bin/env bash
# Offline tests for refresh-gh-secrets.sh: fake `aws` and `gh` on PATH log argv and stdin.
# Needs no credentials and no network. The fake credential values are dummies.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="$SCRIPT_DIR/refresh-gh-secrets.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FAKE_KEY_ID="AKIAFAKEKEYID000"
FAKE_SECRET="fake-secret-access-key-value"
FAKE_TOKEN="fake-session-token-value"

mkdir -p "$WORK/bin"
cat >"$WORK/bin/aws" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >>"$FAKE_AWS_LOG"
case "$*" in
  *"configure get aws_access_key_id"*) echo "AKIAFAKEKEYID000" ;;
  *"configure get aws_secret_access_key"*) echo "fake-secret-access-key-value" ;;
  *"configure get aws_session_token"*) [ "${FAKE_NO_TOKEN:-0}" = "1" ] && exit 1; echo "fake-session-token-value" ;;
  *"sts get-caller-identity"*) [ "${FAKE_STS_FAIL:-0}" = "1" ] && { echo "ExpiredToken" >&2; exit 254; }; echo "123456789012" ;;
esac
exit 0
FAKE
cat >"$WORK/bin/gh" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >>"$FAKE_GH_LOG"
case "$*" in
  "auth status"*) [ "${FAKE_GH_NOAUTH:-0}" = "1" ] && exit 1 ;;
  "secret set"* | "variable set"*) { printf '%s|' "$*"; cat; echo; } >>"$FAKE_GH_STDIN" ;;
esac
exit 0
FAKE
chmod +x "$WORK/bin/aws" "$WORK/bin/gh"

fail=0
err() { echo "FAIL: $*" >&2; fail=1; }

# run <name> [env...] -- [args...]: runs the script, stores stdout/stderr/rc under $WORK/<name>.
run() {
  local name="$1"; shift
  local envs=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  [ "$#" -gt 0 ] && shift
  : >"$WORK/$name.aws"; : >"$WORK/$name.gh"; : >"$WORK/$name.stdin"
  set +e
  env PATH="$WORK/bin:$PATH" FAKE_AWS_LOG="$WORK/$name.aws" FAKE_GH_LOG="$WORK/$name.gh" \
    FAKE_GH_STDIN="$WORK/$name.stdin" "${envs[@]}" bash "$TARGET" "$@" \
    >"$WORK/$name.out" 2>"$WORK/$name.err"
  echo $? >"$WORK/$name.rc"
  set -e
}

# --- happy path: 4 default repos, 3 secrets + 1 variable each
run ok --
[ "$(cat "$WORK/ok.rc")" = 0 ] || err "ok: exit $(cat "$WORK/ok.rc"): $(cat "$WORK/ok.err")"
for repo in user-service nmap-service gateway front; do
  for name in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN; do
    rg -q -F "secret set $name --repo cloud-native-security-app/$repo" "$WORK/ok.gh" || err "ok: missing secret $name on $repo"
  done
  rg -q -F "variable set AWS_REGION --repo cloud-native-security-app/$repo" "$WORK/ok.gh" || err "ok: missing AWS_REGION variable on $repo"
done
[ "$(rg -c -F 'secret set' "$WORK/ok.gh")" = 12 ] || err "ok: expected 12 secret sets"
rg -q -F "configure get aws_access_key_id --profile learnerlab" "$WORK/ok.aws" || err "ok: credentials must come from the learnerlab profile"
rg -q "sts get-caller-identity.*--profile learnerlab" "$WORK/ok.aws" || err "ok: credentials must be validated with STS first"
# values travel on stdin, never in argv
for v in "$FAKE_KEY_ID" "$FAKE_SECRET" "$FAKE_TOKEN"; do
  rg -q -F "$v" "$WORK/ok.gh" && err "ok: a credential value leaked into gh argv"
  rg -q -F "$v" "$WORK/ok.out" "$WORK/ok.err" && err "ok: a credential value was printed"
done
rg -q -F "secret set AWS_SESSION_TOKEN --repo cloud-native-security-app/gateway|$FAKE_TOKEN" "$WORK/ok.stdin" || err "ok: session token not passed on stdin"
rg -q -F "variable set AWS_REGION --repo cloud-native-security-app/front|us-east-1" "$WORK/ok.stdin" || err "ok: region not passed"

# --- expired credentials: no GitHub write at all
run expired FAKE_STS_FAIL=1 --
[ "$(cat "$WORK/expired.rc")" != 0 ] || err "expired: must fail"
rg -q 'set ' "$WORK/expired.gh" && err "expired: must not write any secret"
rg -q -i 'expired|refresh' "$WORK/expired.err" || err "expired: must tell the user to refresh the lab credentials"

# --- missing session token (not lab credentials): fail before writing
run notoken FAKE_NO_TOKEN=1 --
[ "$(cat "$WORK/notoken.rc")" != 0 ] || err "notoken: must fail"
rg -q 'set ' "$WORK/notoken.gh" && err "notoken: must not write any secret"

# --- gh not authenticated: fail before writing
run noauth FAKE_GH_NOAUTH=1 --
[ "$(cat "$WORK/noauth.rc")" != 0 ] || err "noauth: must fail"
rg -q 'set ' "$WORK/noauth.gh" && err "noauth: must not write any secret"

# --- overrides: REPOS, GH_OWNER, AWS_PROFILE, AWS_REGION
run override REPOS="gateway" GH_OWNER="someone" AWS_PROFILE="other" AWS_REGION="us-west-2" --
[ "$(cat "$WORK/override.rc")" = 0 ] || err "override: exit $(cat "$WORK/override.rc")"
[ "$(rg -c -F 'secret set' "$WORK/override.gh")" = 3 ] || err "override: expected 3 secret sets for one repo"
rg -q -F -- "--repo someone/gateway" "$WORK/override.gh" || err "override: GH_OWNER/REPOS ignored"
rg -q -F -- "--profile other" "$WORK/override.aws" || err "override: AWS_PROFILE ignored"
rg -q -F "|us-west-2" "$WORK/override.stdin" || err "override: AWS_REGION ignored"

# --- dry run: validates but writes nothing
run dry -- --dry-run
[ "$(cat "$WORK/dry.rc")" = 0 ] || err "dry: exit $(cat "$WORK/dry.rc")"
rg -q 'set ' "$WORK/dry.gh" && err "dry: must not write"
rg -q -F "cloud-native-security-app/front" "$WORK/dry.out" "$WORK/dry.err" || err "dry: must list the target repos"

if [ "$fail" -ne 0 ]; then exit 1; fi
echo "test-refresh-gh-secrets: OK"
