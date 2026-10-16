#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/00-env.sh"

NET_CONF="awsvpcConfiguration={subnets=[$(cat "$STATE_DIR/subnet_ids.txt")],securityGroups=[$(cat "$STATE_DIR/internal_sg_id.txt")],assignPublicIp=ENABLED}"

ensure_service postgres "$(cat "$STATE_DIR/td_postgres.txt")" \
  --desired-count 1 --launch-type FARGATE \
  --network-configuration "$NET_CONF" \
  --service-connect-configuration "enabled=true,namespace=${NAMESPACE_NAME},services=[{portName=postgres,clientAliases=[{port=5432,dnsName=postgres}]}]"

ensure_service mongo "$(cat "$STATE_DIR/td_mongo.txt")" \
  --desired-count 1 --launch-type FARGATE \
  --network-configuration "$NET_CONF" \
  --service-connect-configuration "enabled=true,namespace=${NAMESPACE_NAME},services=[{portName=mongo,clientAliases=[{port=27017,dnsName=mongo}]}]"

ensure_service rabbitmq "$(cat "$STATE_DIR/td_rabbitmq.txt")" \
  --desired-count 1 --launch-type FARGATE \
  --network-configuration "$NET_CONF" \
  --service-connect-configuration "enabled=true,namespace=${NAMESPACE_NAME},services=[{portName=rabbitmq-amqp,clientAliases=[{port=5672,dnsName=rabbitmq}]},{portName=rabbitmq-amqps,clientAliases=[{port=5671,dnsName=rabbitmq}]}]"

echo "Servicios postgres/mongo/rabbitmq listos. Esperando a que queden estables..."
aws ecs wait services-stable --cluster "$CLUSTER_NAME" --services postgres mongo rabbitmq
echo "Tier 0 (infra) estable."
