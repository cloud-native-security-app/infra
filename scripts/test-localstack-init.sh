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
  "kinesis create-stream" | "kinesis describe-stream-summary")
    # Record whether the readiness marker already exists: it must not.
    if [ -f "$LOCALSTACK_INIT_MARKER" ]; then echo "MARKER_BEFORE_KINESIS $1 $2" >>"$FAKE_AWSLOCAL_LOG"; fi
    ;;&
  "kinesis create-stream")
    case "${FAKE_KINESIS_CREATE:-ok}" in
      exists)
        echo "An error occurred (ResourceInUseException) when calling the CreateStream operation: Stream security-events under account 000000000000 already exists." >&2
        exit 254
        ;;
      fail)
        echo "An error occurred (InternalFailure) when calling the CreateStream operation" >&2
        exit 254
        ;;
    esac
    ;;
  "kinesis describe-stream-summary")
    echo "${FAKE_KINESIS_STATUS:-ACTIVE}"
    ;;
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

# 2. eight queues: three main + three DLQs + the report email queue and its DLQ
for q in ms-nmap-scan-requests ms-nmap-scan-cancellations gateway-scan-outcomes; do
  has "sqs create-queue --queue-name $q" || err "queue $q not created"
  has "sqs create-queue --queue-name $q-dlq" || err "dlq $q-dlq not created"
done
has "sqs create-queue --queue-name user-service-report-emails" || err "report email queue not created"
has "sqs create-queue --queue-name user-service-report-emails-dlq" || err "report email dlq not created"
[ "$(count 'sqs create-queue')" = 8 ] || err "expected 8 queues, got $(count 'sqs create-queue')"

# 3. redrive on the main queues only (the report email queue included), maxReceiveCount 3, targeting the matching DLQ
[ "$(count 'maxReceiveCount')" = 4 ] || err "expected 4 redrive policies, got $(count 'maxReceiveCount')"
for q in ms-nmap-scan-requests ms-nmap-scan-cancellations gateway-scan-outcomes user-service-report-emails; do
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

# 6. visibility timeouts: requests = max(connect + command, local scan) + NVD budget + 60
#    (defaults max(10 + 900, 900) + 300 + 60), others 30
rg -q -- 'VisibilityTimeout[^0-9]+1270[^0-9]' "$LOG" || err "requests visibility timeout is not 1270"
[ "$(count 'VisibilityTimeout')" = 4 ] || err "expected 4 VisibilityTimeout settings (main queues), got $(count 'VisibilityTimeout')"
[ "$(rg -c -- 'VisibilityTimeout[^0-9]+30[^0-9]' "$LOG" || echo 0)" = 2 ] || err "cancellations/outcomes visibility timeout is not 30"

rg -q -- 'VisibilityTimeout[^0-9]+120[^0-9]' "$LOG" || err "report email visibility timeout is not 120"

# 7. the requests timeout follows the nmap-service timeouts passed to the container
LOG="$WORK/custom.log"
: >"$LOG"
PATH="$WORK/bin:$PATH" FAKE_AWSLOCAL_LOG="$LOG" LOCALSTACK_INIT_MARKER="$WORK/custom.marker" \
  SCAN_SSH_CONNECT_TIMEOUT_SECS=5 SCAN_SSH_COMMAND_TIMEOUT_SECS=300 SCAN_LOCAL_TIMEOUT_SECS=100 NVD_ENRICHMENT_BUDGET_SECS=0 \
  bash "$TARGET" >/dev/null 2>&1 || err "custom timeouts: nonzero exit"
rg -q -- 'VisibilityTimeout[^0-9]+365[^0-9]' "$LOG" || err "custom timeouts: expected 365 (max(5 + 300, 100) + 0 + 60)"

# 7b. the local network-mode timeout wins when it is the longest scan
LOG="$WORK/local.log"
: >"$LOG"
PATH="$WORK/bin:$PATH" FAKE_AWSLOCAL_LOG="$LOG" LOCALSTACK_INIT_MARKER="$WORK/local.marker" \
  SCAN_SSH_CONNECT_TIMEOUT_SECS=5 SCAN_SSH_COMMAND_TIMEOUT_SECS=300 SCAN_LOCAL_TIMEOUT_SECS=600 NVD_ENRICHMENT_BUDGET_SECS=30 \
  bash "$TARGET" >/dev/null 2>&1 || err "local timeout: nonzero exit"
rg -q -- 'VisibilityTimeout[^0-9]+690[^0-9]' "$LOG" || err "local timeout: expected 690 (max(5 + 300, 600) + 30 + 60)"

# 8. idempotent: a second run succeeds and issues the same commands
PATH="$WORK/bin:$PATH" FAKE_AWSLOCAL_LOG="$WORK/second.log" LOCALSTACK_INIT_MARKER="$WORK/base.marker" \
  bash "$TARGET" >/dev/null 2>&1 || err "second run: nonzero exit"
[ "$(wc -l <"$WORK/second.log")" = "$(wc -l <"$WORK/base.log")" ] || err "second run issued a different number of commands"

# 9. Kinesis stream security-events: 1 shard, created idempotently, ACTIVE before the marker
has "kinesis create-stream --stream-name security-events --shard-count 1" || err "kinesis stream not created with 1 shard"
[ "$(count 'kinesis create-stream')" = 1 ] || err "expected 1 create-stream, got $(count 'kinesis create-stream')"
has "kinesis describe-stream-summary --stream-name security-events" || err "stream status never checked"
has "MARKER_BEFORE_KINESIS" && err "readiness marker existed while the stream was being created"

# 9b. stream already exists (ResourceInUseException): tolerated
LOG="$WORK/exists.log"
: >"$LOG"
PATH="$WORK/bin:$PATH" FAKE_AWSLOCAL_LOG="$LOG" FAKE_KINESIS_CREATE=exists LOCALSTACK_INIT_MARKER="$WORK/exists.marker" \
  bash "$TARGET" >/dev/null 2>&1 || err "existing stream: nonzero exit"
[ -f "$WORK/exists.marker" ] || err "existing stream: marker not written"

# 9c. any other create-stream failure fails the init and leaves no marker
LOG="$WORK/kfail.log"
: >"$LOG"
rc=0
PATH="$WORK/bin:$PATH" FAKE_AWSLOCAL_LOG="$LOG" FAKE_KINESIS_CREATE=fail LOCALSTACK_INIT_MARKER="$WORK/kfail.marker" \
  bash "$TARGET" >/dev/null 2>&1 || rc=$?
[ "$rc" != 0 ] || err "create-stream failure: script exited 0"
[ ! -f "$WORK/kfail.marker" ] || err "create-stream failure: marker written"

# 9d. a stream that never becomes ACTIVE fails the init (short wait for the test)
LOG="$WORK/creating.log"
: >"$LOG"
rc=0
PATH="$WORK/bin:$PATH" FAKE_AWSLOCAL_LOG="$LOG" FAKE_KINESIS_STATUS=CREATING KINESIS_WAIT_ATTEMPTS=3 KINESIS_WAIT_SLEEP_SECS=0 \
  LOCALSTACK_INIT_MARKER="$WORK/creating.marker" bash "$TARGET" >/dev/null 2>&1 || rc=$?
[ "$rc" != 0 ] || err "stream stuck CREATING: script exited 0"
[ ! -f "$WORK/creating.marker" ] || err "stream stuck CREATING: marker written"

# 9e. compose wiring: LocalStack enables kinesis; the three producers get the stream name
# (events-service, the consumer, is checked in 9f)
COMPOSE="$SCRIPT_DIR/../docker-compose.yml"
rg -q -- 'SERVICES: sns,sqs,kinesis' "$COMPOSE" || err "compose SERVICES does not include kinesis"
[ "$(rg -c -- 'SECURITY_EVENTS_STREAM_NAME: "security-events"' "$COMPOSE" || echo 0)" = 4 ] \
  || err "expected SECURITY_EVENTS_STREAM_NAME in gateway, nmap-service, user-service and events-service"
for svc in user-service nmap-service gateway; do
  awk -v s="  $svc:" '$0==s{f=1;next} /^  [a-z-]+:/{f=0} f' "$COMPOSE" | rg -q -- 'SECURITY_EVENTS_STREAM_NAME: "security-events"' \
    || err "$svc lacks SECURITY_EVENTS_STREAM_NAME"
done

# 9f. events-service: reads the stream from LocalStack, gets a dev shared secret that
# the gateway sends, and waits for LocalStack to be healthy
ES="$(awk '$0=="  events-service:"{f=1;next} /^  [a-z-]+:/{f=0} f' "$COMPOSE")"
GW="$(awk '$0=="  gateway:"{f=1;next} /^  [a-z-]+:/{f=0} f' "$COMPOSE")"
[ -n "$ES" ] || err "compose has no events-service"
for pat in 'build: ../events-service' 'SECURITY_EVENTS_STREAM_NAME: "security-events"' 'AWS_ENDPOINT_URL: "http://localstack:4566"' \
  'AWS_REGION: us-east-1' 'AWS_ACCESS_KEY_ID: test' 'GATEWAY_SHARED_SECRET: dev-events-shared-secret' 'HTTP_PORT: "8080"'; do
  printf '%s\n' "$ES" | rg -qF -- "$pat" || err "events-service lacks: $pat"
done
if ! { printf '%s\n' "$ES" | rg -q 'localstack:\s*$' && printf '%s\n' "$ES" | rg -q 'condition: service_healthy'; }; then
  err "events-service does not wait for localstack to be healthy"
fi
printf '%s\n' "$GW" | rg -qF 'EVENTS_SERVICE_BASE_URL: "http://events-service:8080"' || err "gateway lacks EVENTS_SERVICE_BASE_URL"
printf '%s\n' "$GW" | rg -qF 'EVENTS_SERVICE_SHARED_SECRET: dev-events-shared-secret' || err "gateway lacks EVENTS_SERVICE_SHARED_SECRET matching the events-service secret"

# 9g. user-service gets the report email queue and DLQ URLs and waits for LocalStack
US="$(awk '$0=="  user-service:"{f=1;next} /^  [a-z-]+:/{f=0} f' "$COMPOSE")"
for pat in 'REPORT_EMAIL_QUEUE_URL: "http://localstack:4566/000000000000/user-service-report-emails"' \
  'REPORT_EMAIL_DLQ_URL: "http://localstack:4566/000000000000/user-service-report-emails-dlq"'; do
  printf '%s\n' "$US" | rg -qF -- "$pat" || err "user-service lacks: $pat"
done
printf '%s\n' "$US" | rg -q 'localstack:\s*$' || err "user-service does not wait for localstack"

# 10. readiness marker: written at the end, only on success
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
