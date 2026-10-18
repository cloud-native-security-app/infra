#!/usr/bin/env bash
# Offline tests for bootstrap-namespace.sh: a fake `aws` on PATH logs argv.
# Needs no credentials and no network.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="$SCRIPT_DIR/bootstrap-namespace.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

ARN="arn:aws:servicediscovery:us-east-1:123456789012:namespace/ns-abc"

# Fake aws knobs (env): FAKE_NS_EXISTS=1 namespace already listed;
# FAKE_NS_APPEARS=0 it never appears after create-cluster;
# FAKE_CREATE_FAILS=N the first N create-cluster calls fail with the service-linked-role error.
mkdir -p "$WORK/bin"
cat >"$WORK/bin/aws" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >>"$FAKE_AWS_LOG"
case "$*" in
  *"ecs create-cluster"*)
    n="$(cat "$FAKE_STATE.fails" 2>/dev/null || echo 0)"
    if [ "$n" -lt "${FAKE_CREATE_FAILS:-0}" ]; then
      echo $((n + 1)) >"$FAKE_STATE.fails"
      echo "An error occurred (InvalidParameterException): Unable to assume the service linked role." >&2
      exit 255
    fi
    touch "$FAKE_STATE.created" ;;
  *"servicediscovery list-namespaces"*)
    if [ "${FAKE_NS_EXISTS:-0}" = "1" ] || { [ "${FAKE_NS_APPEARS:-1}" = "1" ] && [ -e "$FAKE_STATE.created" ]; }; then
      echo "arn:aws:servicediscovery:us-east-1:123456789012:namespace/ns-abc"
    else
      echo "None"
    fi ;;
esac
exit 0
FAKE
chmod +x "$WORK/bin/aws"

fail=0
err() { echo "FAIL: $*" >&2; fail=1; }

# run_case <name> [script args...]; env knobs come from the caller. Sets OUT, ERR, LOG, RC.
run_case() {
  local name="$1"
  shift
  LOG="$WORK/$name.log"
  : >"$LOG"
  RC=0
  PATH="$WORK/bin:$PATH" FAKE_AWS_LOG="$LOG" FAKE_STATE="$WORK/$name.state" \
    SLEEP_SECONDS=0 bash "$TARGET" "$@" >"$WORK/$name.out" 2>"$WORK/$name.err" || RC=$?
  OUT="$WORK/$name.out"
  ERR="$WORK/$name.err"
}

has() { rg -q -- "$1" "$LOG"; }
count() { rg -c -- "$1" "$LOG" || true; }

# 1. namespace already present: nothing mutating, ARN printed last
FAKE_NS_EXISTS=1 run_case existing
[ "$RC" -eq 0 ] || err "existing: exit $RC"
has 'ecs create-cluster' && err "existing: create-cluster called"
has 'ecs delete-cluster' && err "existing: delete-cluster called"
[ "$(tail -1 "$OUT")" = "$ARN" ] || err "existing: last stdout line is not the namespace ARN"
has '--region us-east-1' || err "existing: --region not passed"

# 2. namespace missing: throwaway cluster creates it, then is deleted
run_case missing
[ "$RC" -eq 0 ] || err "missing: exit $RC"
has 'ecs create-cluster --cluster-name security-app-ns-bootstrap .*--service-connect-defaults namespace=security-app.local' || err "missing: create-cluster without service-connect-defaults namespace"
has '--region us-east-1 ecs create-cluster' || err "missing: create-cluster without --region"
has 'ecs delete-cluster --cluster security-app-ns-bootstrap' || err "missing: throwaway cluster not deleted"
[ "$(tail -1 "$OUT")" = "$ARN" ] || err "missing: last stdout line is not the namespace ARN"
has 'delete-namespace|create-http-namespace' && err "missing: namespace API mutated directly"

# 3. service-linked-role error is retried
FAKE_CREATE_FAILS=2 run_case retry
[ "$RC" -eq 0 ] || err "retry: exit $RC"
[ "$(count 'ecs create-cluster')" = "3" ] || err "retry: expected 3 create-cluster calls, got $(count 'ecs create-cluster')"
has 'ecs delete-cluster' || err "retry: throwaway cluster not deleted"

# 4. namespace never appears: non-zero exit, throwaway cluster still deleted
FAKE_NS_APPEARS=0 run_case timeout
[ "$RC" -ne 0 ] || err "timeout: expected non-zero exit"
has 'ecs delete-cluster --cluster security-app-ns-bootstrap' || err "timeout: throwaway cluster not deleted"
has 'delete-namespace' && err "timeout: namespace deleted"
rg -q 'did not appear' "$ERR" || err "timeout: no clear message"

# 5. create-cluster keeps failing: non-zero exit, nothing to delete is fine, no namespace API
FAKE_CREATE_FAILS=99 run_case giveup
[ "$RC" -ne 0 ] || err "giveup: expected non-zero exit"
has 'delete-namespace|create-http-namespace' && err "giveup: namespace API called"

# 6. env overrides
PROJECT=demo FAKE_NS_EXISTS=1 run_case project
rg -q 'Name==.demo.local.' "$LOG" || err "PROJECT override ignored in the namespace lookup"

# 7. dry-run: no mutating call
run_case dry --dry-run
[ "$RC" -eq 0 ] || err "dry-run: exit $RC"
has 'ecs (create|delete)-cluster' && err "dry-run: mutating call executed"
rg -q 'create-cluster' "$ERR" || err "dry-run: plan not printed"

[ "$fail" -eq 0 ] && echo "test-bootstrap-namespace: OK"
exit "$fail"
