#!/usr/bin/env bash
# LocalStack init hook (runs in the container, mounted under
# /etc/localstack/init/ready.d/). Creates the same SNS + SQS topology as
# terraform/messaging.tf, minus encryption, retention and resource policies
# (LocalStack does not enforce them). Idempotent: safe to run on every start.
#
# Env (all optional):
#   AWS_REGION / AWS_DEFAULT_REGION     region baked into the ARNs (default us-east-1)
#   LOCALSTACK_ACCOUNT_ID               account baked into the ARNs (default 000000000000)
#   SCAN_SSH_CONNECT_TIMEOUT_SECS       nmap-service SSH connect timeout (default 10)
#   SCAN_SSH_COMMAND_TIMEOUT_SECS       nmap-service SSH command timeout (default 900)
#   LOCALSTACK_INIT_MARKER              readiness marker, written last (default /tmp/localstack-init.done)
set -euo pipefail

REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
ACCOUNT="${LOCALSTACK_ACCOUNT_ID:-000000000000}"
MARKER="${LOCALSTACK_INIT_MARKER:-/tmp/localstack-init.done}"
CONNECT_TIMEOUT="${SCAN_SSH_CONNECT_TIMEOUT_SECS:-10}"
COMMAND_TIMEOUT="${SCAN_SSH_COMMAND_TIMEOUT_SECS:-900}"
MAX_RECEIVE_COUNT=3

# A scan never outlives its SSH timeouts (same formula as terraform/messaging.tf).
REQUESTS_VISIBILITY=$((CONNECT_TIMEOUT + COMMAND_TIMEOUT + 60))

# The healthcheck reads the marker, so drop a stale one from a previous run first.
rm -f "$MARKER"

topic_arn() { echo "arn:aws:sns:$REGION:$ACCOUNT:$1"; }
queue_arn() { echo "arn:aws:sqs:$REGION:$ACCOUNT:$1"; }

# create_queue <name> [visibility-timeout dlq-name]
# Creates the queue, then sets attributes separately: create-queue fails on an
# existing queue whose attributes differ, set-queue-attributes does not.
# Without attributes (a DLQ) it keeps the defaults, as in terraform.
create_queue() {
  local name="$1" visibility="${2:-}" dlq="${3:-}" url redrive
  url="$(awslocal sqs create-queue --queue-name "$name" --query QueueUrl --output text)"
  [ -n "$visibility" ] || return 0
  redrive="{\\\"deadLetterTargetArn\\\":\\\"$(queue_arn "$dlq")\\\",\\\"maxReceiveCount\\\":\\\"$MAX_RECEIVE_COUNT\\\"}"
  awslocal sqs set-queue-attributes --queue-url "$url" \
    --attributes "{\"VisibilityTimeout\":\"$visibility\",\"RedrivePolicy\":\"$redrive\"}"
}

# subscribe <topic> <queue> [filter-policy-json]
subscribe() {
  local topic="$1" queue="$2" filter="${3:-}" sub
  sub="$(awslocal sns subscribe --topic-arn "$(topic_arn "$topic")" --protocol sqs \
    --notification-endpoint "$(queue_arn "$queue")" --query SubscriptionArn --output text)"
  awslocal sns set-subscription-attributes --subscription-arn "$sub" \
    --attribute-name RawMessageDelivery --attribute-value true
  if [ -n "$filter" ]; then
    awslocal sns set-subscription-attributes --subscription-arn "$sub" \
      --attribute-name FilterPolicy --attribute-value "$filter"
  fi
}

for topic in scan-requests scan-cancellations scan-outcomes; do
  awslocal sns create-topic --name "$topic" >/dev/null
done

# queue | visibility timeout (s)
for spec in \
  "ms-nmap-scan-requests|$REQUESTS_VISIBILITY" \
  "ms-nmap-scan-cancellations|30" \
  "gateway-scan-outcomes|30"; do
  IFS='|' read -r queue visibility <<<"$spec"
  create_queue "$queue-dlq"
  create_queue "$queue" "$visibility" "$queue-dlq"
done

subscribe scan-requests ms-nmap-scan-requests
subscribe scan-cancellations ms-nmap-scan-cancellations
subscribe scan-outcomes gateway-scan-outcomes '{"routing_key":[{"prefix":"scan.outcome."}]}'

touch "$MARKER"
echo "localstack-init: topology ready (region $REGION, account $ACCOUNT)"
