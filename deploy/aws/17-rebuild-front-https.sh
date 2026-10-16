#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/00-env.sh"
cd "$REPO_ROOT"

GATEWAY_PUBLIC_URL=$(cat "$STATE_DIR/gateway_public_url.txt")
if [[ "$GATEWAY_PUBLIC_URL" != https://* ]]; then
  echo "gateway_public_url.txt todavía es http:// — corre primero ./15-enable-https-gateway.sh" >&2
  exit 1
fi

docker build \
  --build-arg VITE_GATEWAY_BASE_URL="$GATEWAY_PUBLIC_URL" \
  -t "$IMG_FRONT" ./front
docker push "$IMG_FRONT"

echo "front reconstruido con VITE_GATEWAY_BASE_URL=$GATEWAY_PUBLIC_URL"

aws ecs update-service --cluster "$CLUSTER_NAME" --service front \
  --force-new-deployment >/dev/null
echo "Esperando a que front quede estable con la nueva imagen..."
aws ecs wait services-stable --cluster "$CLUSTER_NAME" --services front
echo "front actualizado. Login real listo — abre $(front_public_url)/"
