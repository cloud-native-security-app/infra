#!/usr/bin/env bash
# Offline tests for localstack-init.sh: a fake `awslocal` on PATH logs argv.
# Needs no docker, no LocalStack and no network.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="$SCRIPT_DIR/localstack-init.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

ACCT="000000000000"
REG="us-east-1"

mkdir -p "$WORK/bin"
cat >"$WORK/bin/awslocal" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >>"$FAKE_AWSLOCAL_LOG"
name=""
prev=""
for a in "$@"; do
  case "$prev" in
    --queue-name | --name) name="$a" ;;
  esac
  prev="$a"
done
case "$1 $2" in
  "sqs create-queue") echo "http://localhost:4566/000000000000/$name" ;;
  "sns subscribe") echo "arn:aws:sns:us-east-1:000000000000:topic:sub-$RANDOM" ;;
esac
exit 0
FAKE
chmod +x "$WORK/bin/awslocal"

fail=0
err() { echo "FAIL: $*" >&2; fail=1; }

# run_case <name>; env knobs come from the caller. Sets LOG, RC.
run_case() {
  local name="$1"
  LOG="$WORK/$name.log"
  : >"$LOG"
  RC=0
  PATH="$WORK/bin:$PATH" FAKE_AWSLOCAL_LOG="$LOG" LOCALSTACK_INIT_MARKER="$WORK/$name.marker" \
    bash "$TARGET" >"$WORK/$name.out" 2>"$WORK/$name.err" || RC=$?
}

has() { rg -q -F -- "$1" "$LOG"; }
count() { rg -c -F -- "$1" "$LOG" || echo 0; }

run_case base
[ "$RC" = 0 ] || err "exit $RC (stderr: $(head -c 300 "$WORK/base.err" 2>&1))"

# 1. three topics
for t in scan-requests scan-cancellations scan-outcomes; do
  has "sns create-topic --name $t" || err "topic $t not created"
done
[ "$(count 'sns create-topic')" = 3 ] || err "expected 3 topics, got $(count 'sns create-topic')"

# 2. six queues: three main + three DLQs
for q in ms-nmap-scan-requests ms-nmap-scan-cancellations gateway-scan-outcomes; do
  has "sqs create-queue --queue-name $q" || err "queue $q not created"
  has "sqs create-queue --queue-name $q-dlq" || err "dlq $q-dlq not created"
done
[ "$(count 'sqs create-queue')" = 6 ] || err "expected 6 queues, got $(count 'sqs create-queue')"

# 3. redrive on the three main queues only, maxReceiveCount 3, targeting the matching DLQ
[ "$(count 'maxReceiveCount')" = 3 ] || err "expected 3 redrive policies, got $(count 'maxReceiveCount')"
for q in ms-nmap-scan-requests ms-nmap-scan-cancellations gateway-scan-outcomes; do
  rg -q -F -- "arn:aws:sqs:$REG:$ACCT:$q-dlq" "$LOG" || err "no redrive target for $q-dlq"
done
rg -q -- 'maxReceiveCount[^0-9]+3[^0-9]' "$LOG" || err "maxReceiveCount is not 3"
[ "$(rg -o -- 'maxReceiveCount[^0-9]+[0-9]+' "$LOG" | rg -o '[0-9]+$' | sort -u)" = 3 ] || err "a redrive policy has maxReceiveCount other than 3"

# 4. subscriptions: three, each raw delivery, topic -> queue pairing as in messaging.tf
[ "$(count 'sns subscribe')" = 3 ] || err "expected 3 subscriptions, got $(count 'sns subscribe')"
[ "$(count 'RawMessageDelivery --attribute-value true')" = 3 ] || err "expected 3 RawMessageDelivery=true"
pairs=("scan-requests:ms-nmap-scan-requests" "scan-cancellations:ms-nmap-scan-cancellations" "scan-outcomes:gateway-scan-outcomes")
for p in "${pairs[@]}"; do
  t="${p%%:*}"
  q="${p##*:}"
  rg -q -F -- "--topic-arn arn:aws:sns:$REG:$ACCT:$t --protocol sqs --notification-endpoint arn:aws:sqs:$REG:$ACCT:$q" "$LOG" \
    || err "subscription $t -> $q missing"
done

# 5. filter policy only on the outcomes subscription
[ "$(count 'FilterPolicy')" = 1 ] || err "expected exactly 1 FilterPolicy, got $(count 'FilterPolicy')"
rg -q -F -- '{"routing_key":[{"prefix":"scan.outcome."}]}' "$LOG" || err "outcomes filter policy missing or different"

# 6. visibility timeouts: requests = connect + command + 60 (defaults 10 + 900), others 30
rg -q -- 'VisibilityTimeout[^0-9]+970[^0-9]' "$LOG" || err "requests visibility timeout is not 970"
[ "$(count 'VisibilityTimeout')" = 3 ] || err "expected 3 VisibilityTimeout settings (main queues), got $(count 'VisibilityTimeout')"
[ "$(rg -c -- 'VisibilityTimeout[^0-9]+30[^0-9]' "$LOG" || echo 0)" = 2 ] || err "cancellations/outcomes visibility timeout is not 30"

# 7. the requests timeout follows the nmap-service timeouts passed to the container
LOG="$WORK/custom.log"
: >"$LOG"
PATH="$WORK/bin:$PATH" FAKE_AWSLOCAL_LOG="$LOG" LOCALSTACK_INIT_MARKER="$WORK/custom.marker" \
  SCAN_SSH_CONNECT_TIMEOUT_SECS=5 SCAN_SSH_COMMAND_TIMEOUT_SECS=300 bash "$TARGET" >/dev/null 2>&1 || err "custom timeouts: nonzero exit"
rg -q -- 'VisibilityTimeout[^0-9]+365[^0-9]' "$LOG" || err "custom timeouts: expected 365 (5 + 300 + 60)"

# 8. idempotent: a second run succeeds and issues the same commands
PATH="$WORK/bin:$PATH" FAKE_AWSLOCAL_LOG="$WORK/second.log" LOCALSTACK_INIT_MARKER="$WORK/base.marker" \
  bash "$TARGET" >/dev/null 2>&1 || err "second run: nonzero exit"
[ "$(wc -l <"$WORK/second.log")" = "$(wc -l <"$WORK/base.log")" ] || err "second run issued a different number of commands"

# 9. readiness marker: written at the end, only on success
[ -f "$WORK/base.marker" ] || err "ready marker not written"
cat >"$WORK/bin/awslocal-fail" <<'FAKE'
#!/usr/bin/env bash
exit 1
FAKE
chmod +x "$WORK/bin/awslocal-fail"
mkdir -p "$WORK/failbin"
cp "$WORK/bin/awslocal-fail" "$WORK/failbin/awslocal"
rc=0
PATH="$WORK/failbin:$PATH" LOCALSTACK_INIT_MARKER="$WORK/fail.marker" bash "$TARGET" >/dev/null 2>&1 || rc=$?
[ "$rc" != 0 ] || err "failing awslocal: script exited 0"
[ ! -f "$WORK/fail.marker" ] || err "failing awslocal: marker written"

if [ "$fail" -eq 0 ]; then echo "test-localstack-init: OK"; fi
exit "$fail"
