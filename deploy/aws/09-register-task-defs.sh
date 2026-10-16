#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/00-env.sh"

EXEC_ROLE_ARN=$(cat "$STATE_DIR/exec_role_arn.txt")
GATEWAY_PUBLIC_URL=$(cat "$STATE_DIR/gateway_public_url.txt")
# Adonde redirige gateway tras el login (feature post_login_redirect), y
# origen permitido por su CORS — front queda en el puerto default del mismo
# ALB (http:// hasta que 15-enable-https-gateway.sh lo pasa a https://).
FRONT_PUBLIC_URL="$(front_public_url)"

load_google_oauth
if [ -n "${GOOGLE_CLIENT_ID:-}" ]; then
  command -v jq >/dev/null || { echo "Falta 'jq' instalado (necesario para conservar las credenciales OAuth de gateway)" >&2; exit 1; }
  echo "gateway se registrará con las credenciales OAuth guardadas (client_id=${GOOGLE_CLIENT_ID%%-*}-...)."
else
  echo "Aviso: sin credenciales OAuth guardadas — gateway queda con dev-placeholder hasta correr 16-update-gateway-oauth.sh."
fi

register() {
  local file="$1"
  local rendered
  rendered=$(sed \
    -e "s#__EXEC_ROLE_ARN__#${EXEC_ROLE_ARN}#g" \
    -e "s#__AWS_REGION__#${AWS_REGION}#g" \
    -e "s#__IMG_POSTGRES__#${IMG_POSTGRES}#g" \
    -e "s#__IMG_MONGO__#${IMG_MONGO}#g" \
    -e "s#__IMG_RABBITMQ__#${IMG_RABBITMQ}#g" \
    -e "s#__IMG_USER_SERVICE__#${IMG_USER_SERVICE}#g" \
    -e "s#__IMG_NMAP_SERVICE__#${IMG_NMAP_SERVICE}#g" \
    -e "s#__IMG_GATEWAY__#${IMG_GATEWAY}#g" \
    -e "s#__IMG_FRONT__#${IMG_FRONT}#g" \
    -e "s#__GATEWAY_PUBLIC_URL__#${GATEWAY_PUBLIC_URL}#g" \
    -e "s#__FRONT_PUBLIC_URL__#${FRONT_PUBLIC_URL}#g" \
    "$file")
  # gateway conserva las credenciales OAuth reales si 16 ya las guardó.
  if [ "$(basename "$file")" = "gateway.json" ] && [ -n "${GOOGLE_CLIENT_ID:-}" ]; then
    rendered=$(echo "$rendered" | apply_google_oauth)
  fi
  aws ecs register-task-definition --cli-input-json "$rendered" \
    --query 'taskDefinition.taskDefinitionArn' --output text
}

DIR="$(dirname "${BASH_SOURCE[0]}")/task-defs"
register "$DIR/postgres.json"     > "$STATE_DIR/td_postgres.txt"
register "$DIR/mongo.json"        > "$STATE_DIR/td_mongo.txt"
register "$DIR/rabbitmq.json"     > "$STATE_DIR/td_rabbitmq.txt"
register "$DIR/user-service.json" > "$STATE_DIR/td_user_service.txt"
register "$DIR/nmap-service.json" > "$STATE_DIR/td_nmap_service.txt"
register "$DIR/gateway.json"      > "$STATE_DIR/td_gateway.txt"
register "$DIR/front.json"        > "$STATE_DIR/td_front.txt"

echo "7 task definitions registradas:"
for f in postgres mongo rabbitmq user_service nmap_service gateway front; do
  echo "  $f -> $(cat "$STATE_DIR/td_${f}.txt")"
done
