#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/00-env.sh"

NET_CONF="awsvpcConfiguration={subnets=[$(cat "$STATE_DIR/subnet_ids.txt")],securityGroups=[$(cat "$STATE_DIR/internal_sg_id.txt")],assignPublicIp=ENABLED}"

ensure_service user-service "$(cat "$STATE_DIR/td_user_service.txt")" \
  --desired-count 1 --launch-type FARGATE \
  --network-configuration "$NET_CONF" \
  --service-connect-configuration "enabled=true,namespace=${NAMESPACE_NAME},services=[{portName=user-service,clientAliases=[{port=8080,dnsName=user-service}]}]"

# nmap-service es puramente cliente de Service Connect (necesita resolver
# `mongo` y `rabbitmq` por DNS interno) — no publica ningún puerto propio,
# así que va sin `services=[...]`.
ensure_service nmap-service "$(cat "$STATE_DIR/td_nmap_service.txt")" \
  --desired-count 1 --launch-type FARGATE \
  --network-configuration "$NET_CONF" \
  --service-connect-configuration "enabled=true,namespace=${NAMESPACE_NAME}"

echo "Servicios user-service/nmap-service listos. Esperando a que queden estables..."
aws ecs wait services-stable --cluster "$CLUSTER_NAME" --services user-service nmap-service
echo "Tier 1 estable."
