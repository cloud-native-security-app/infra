#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/00-env.sh"

NET_CONF="awsvpcConfiguration={subnets=[$(cat "$STATE_DIR/subnet_ids.txt")],securityGroups=[$(cat "$STATE_DIR/internal_sg_id.txt")],assignPublicIp=ENABLED}"
TG_GATEWAY_ARN=$(cat "$STATE_DIR/tg_gateway_arn.txt")

ensure_service gateway "$(cat "$STATE_DIR/td_gateway.txt")" \
  --desired-count 1 --launch-type FARGATE \
  --network-configuration "$NET_CONF" \
  --service-connect-configuration "enabled=true,namespace=${NAMESPACE_NAME}" \
  --load-balancers "targetGroupArn=${TG_GATEWAY_ARN},containerName=gateway,containerPort=8080"

echo "Servicio gateway listo. Esperando a que quede estable..."
aws ecs wait services-stable --cluster "$CLUSTER_NAME" --services gateway
echo "Tier 2 (gateway) estable."
echo "Probar: curl -ik $(cat "$STATE_DIR/gateway_public_url.txt")/health"
