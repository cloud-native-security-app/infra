#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/00-env.sh"
cd "$REPO_ROOT"

ALB_DNS=$(cat "$STATE_DIR/alb_dns.txt")
# Si 15-enable-https-gateway.sh ya corrió (URL https:// guardada para este
# mismo ALB), se respeta en vez de volver a http://.
GATEWAY_PUBLIC_URL=$(cat "$STATE_DIR/gateway_public_url.txt" 2>/dev/null || true)
if [[ "$GATEWAY_PUBLIC_URL" != "https://${ALB_DNS}:8080" ]]; then
  GATEWAY_PUBLIC_URL="http://${ALB_DNS}:8080"
fi
echo "$GATEWAY_PUBLIC_URL" > "$STATE_DIR/gateway_public_url.txt"

# VITE_GATEWAY_BASE_URL se hornea en el bundle JS en build-time (Vite) y
# también parametriza la CSP de nginx.conf.template — no se puede fijar en
# runtime (ver front/Dockerfile). Por eso este build espera a que el ALB
# exista (06-alb.sh) para conocer su DNS público real.
docker build \
  --build-arg VITE_GATEWAY_BASE_URL="$GATEWAY_PUBLIC_URL" \
  -t "$IMG_FRONT" ./front
docker push "$IMG_FRONT"

echo "front construido con VITE_GATEWAY_BASE_URL=$GATEWAY_PUBLIC_URL"
echo
echo "NOTA: si el ALB se recrea después con un DNS distinto, hay que volver a"
echo "correr SOLO este script y luego forzar un redeploy de front:"
echo "  aws ecs update-service --cluster \$CLUSTER_NAME --service front --force-new-deployment"
