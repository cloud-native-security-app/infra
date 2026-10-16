#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/00-env.sh"

ALB_DNS=$(cat "$STATE_DIR/alb_dns.txt")

echo "== gateway /health =="
curl -i "http://${ALB_DNS}:8080/health" || true
echo

echo "== gateway OpenAPI =="
curl -s "http://${ALB_DNS}:8080/api/openapi.json" | head -c 300; echo
echo

echo "== gateway /auth/login (302 esperado hacia Google; falla ahí por credenciales placeholder, es esperado) =="
curl -i "http://${ALB_DNS}:8080/auth/login" || true
echo

echo "== front sirve la SPA =="
curl -s -o /dev/null -w "HTTP %{http_code}\n" "http://${ALB_DNS}/"
echo "Abrir en navegador: http://${ALB_DNS}/  -> debe verse la pantalla de login"
echo

echo "== estado de los 7 services =="
aws ecs describe-services --cluster "$CLUSTER_NAME" \
  --services postgres mongo rabbitmq user-service nmap-service gateway front \
  --query 'services[].{name:serviceName,running:runningCount,desired:desiredCount,status:status}' \
  --output table

cat <<'EOF'

Si algo falla, revisar en este orden:
1. aws ecs describe-services --cluster $CLUSTER_NAME --services <svc> --query 'services[0].events'
2. aws logs tail /ecs/security-app/<svc> --follow
   - user-service: buscar "DatabaseConnectionFailed" (boot-race con postgres; ECS reintenta solo)
   - nmap-service: buscar "no se pudo conectar al Broker (AMQPS)" -> revisar SSL_CERT_FILE / SG puerto 5671
   - gateway: sin logs de arranque tras varios minutos -> revisar target group health
3. aws elbv2 describe-target-health --target-group-arn <tg-arn>

user-service NO tiene target group (no debe exponerse a internet): verificar
solo vía logs, no por curl externo.
EOF
