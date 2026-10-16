#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/00-env.sh"

# Exportadas en el shell, o las guardadas por una corrida anterior de este
# script (.state/google_oauth.env).
load_google_oauth
: "${GOOGLE_CLIENT_ID:?Falta exportar GOOGLE_CLIENT_ID (ver output de 15-enable-https-gateway.sh)}"
: "${GOOGLE_CLIENT_SECRET:?Falta exportar GOOGLE_CLIENT_SECRET (ver output de 15-enable-https-gateway.sh)}"

command -v jq >/dev/null || { echo "Falta 'jq' instalado (necesario para este script)" >&2; exit 1; }

# Se guardan para que 09-register-task-defs.sh las conserve al re-registrar.
save_google_oauth

EXEC_ROLE_ARN=$(cat "$STATE_DIR/exec_role_arn.txt")
GATEWAY_PUBLIC_URL=$(cat "$STATE_DIR/gateway_public_url.txt")
FRONT_PUBLIC_URL="$(front_public_url)"

if [[ "$GATEWAY_PUBLIC_URL" != https://* ]]; then
  echo "gateway_public_url.txt todavía es http:// — corre primero ./15-enable-https-gateway.sh" >&2
  exit 1
fi

DIR="$(dirname "${BASH_SOURCE[0]}")/task-defs"

# 1) Mismos placeholders que 09-register-task-defs.sh (rol, región, imagen,
#    URL pública de gateway y de front). No se escribe nada de vuelta al
#    archivo del repo.
RENDERED=$(sed \
  -e "s#__EXEC_ROLE_ARN__#${EXEC_ROLE_ARN}#g" \
  -e "s#__AWS_REGION__#${AWS_REGION}#g" \
  -e "s#__IMG_GATEWAY__#${IMG_GATEWAY}#g" \
  -e "s#__GATEWAY_PUBLIC_URL__#${GATEWAY_PUBLIC_URL}#g" \
  -e "s#__FRONT_PUBLIC_URL__#${FRONT_PUBLIC_URL}#g" \
  "$DIR/gateway.json")

# 2) Credenciales reales (ver apply_google_oauth en 00-env.sh).
FINAL=$(echo "$RENDERED" | apply_google_oauth)

NEW_TD_ARN=$(aws ecs register-task-definition --cli-input-json "$FINAL" \
  --query 'taskDefinition.taskDefinitionArn' --output text)
echo "$NEW_TD_ARN" > "$STATE_DIR/td_gateway.txt"
echo "Nueva task definition de gateway: $NEW_TD_ARN"

aws ecs update-service --cluster "$CLUSTER_NAME" --service gateway \
  --task-definition "$NEW_TD_ARN" >/dev/null
echo "Esperando a que gateway quede estable con las credenciales reales..."
aws ecs wait services-stable --cluster "$CLUSTER_NAME" --services gateway
echo "gateway actualizado con OAuth real."
