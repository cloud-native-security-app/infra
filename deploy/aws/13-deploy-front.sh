#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/00-env.sh"

NET_CONF="awsvpcConfiguration={subnets=[$(cat "$STATE_DIR/subnet_ids.txt")],securityGroups=[$(cat "$STATE_DIR/internal_sg_id.txt")],assignPublicIp=ENABLED}"
TG_FRONT_ARN=$(cat "$STATE_DIR/tg_front_arn.txt")

# front no lleva --service-connect-configuration: no necesita resolver ningún
# nombre interno (solo lo llama el navegador del usuario, vía la URL pública
# del ALB ya horneada en el bundle JS, nunca server-to-server).
ensure_service front "$(cat "$STATE_DIR/td_front.txt")" \
  --desired-count 1 --launch-type FARGATE \
  --network-configuration "$NET_CONF" \
  --load-balancers "targetGroupArn=${TG_FRONT_ARN},containerName=front,containerPort=8080"

echo "Servicio front listo. Esperando a que quede estable..."
aws ecs wait services-stable --cluster "$CLUSTER_NAME" --services front
echo "Listo. Front público: $(front_public_url)/"
