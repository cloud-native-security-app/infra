#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/00-env.sh"

# Habilita HTTPS en el ALB para poder registrar una app OAuth real en Google
# (exige redirect_uri `https://`, salvo `localhost`):
#   - :8080 (gateway) pasa de HTTP a HTTPS.
#   - :443  (front) nuevo listener HTTPS, y :80 pasa a redirigir a :443.
# front también tiene que ir por HTTPS: gateway emite la cookie de sesión
# con `Secure` + `SameSite=Strict`, y para el navegador http://ALB y
# https://ALB:8080 son sitios distintos (schemeful same-site) — con front en
# http:// la cookie nunca viaja en sus fetch() al gateway y todo da 401 tras
# el login. Con ambos en https:// sobre el mismo host sí es same-site.
#
# Certificado autofirmado (mismo patrón que
# broker/rabbitmq/generate-lab-certs.sh), sin dominio ni costo — el
# navegador mostrará una advertencia de seguridad, aceptada para esta demo
# (ver README.md). Un mismo certificado cubre ambos puertos (el certificado
# va atado al hostname, no al puerto).
#
# Idempotente: reutiliza el certificado ya importado si sigue en ACM y
# modifica los listeners existentes en vez de duplicarlos.

ALB_DNS=$(cat "$STATE_DIR/alb_dns.txt")
ALB_ARN=$(cat "$STATE_DIR/alb_arn.txt")
TG_GATEWAY_ARN=$(cat "$STATE_DIR/tg_gateway_arn.txt")
TG_FRONT_ARN=$(cat "$STATE_DIR/tg_front_arn.txt")

CERT_DIR="$STATE_DIR/gateway-cert"
mkdir -p "$CERT_DIR"

CERT_ARN=$(cat "$STATE_DIR/gateway_cert_arn.txt" 2>/dev/null || true)
if [ -n "$CERT_ARN" ] && aws acm describe-certificate --certificate-arn "$CERT_ARN" >/dev/null 2>&1; then
  echo "Reutilizando certificado ya importado: $CERT_ARN"
else
  echo "Generando certificado autofirmado para $ALB_DNS ..."
  openssl req -x509 -nodes -newkey rsa:2048 \
    -keyout "$CERT_DIR/alb-selfsigned.key" \
    -out "$CERT_DIR/alb-selfsigned.crt" \
    -days 365 \
    -subj "/CN=${ALB_DNS}" \
    -addext "subjectAltName=DNS:${ALB_DNS}" 2>/dev/null

  CERT_ARN=$(aws acm import-certificate \
    --certificate "fileb://$CERT_DIR/alb-selfsigned.crt" \
    --private-key "fileb://$CERT_DIR/alb-selfsigned.key" \
    --query 'CertificateArn' --output text)
  echo "$CERT_ARN" > "$STATE_DIR/gateway_cert_arn.txt"
  echo "Certificado importado a ACM: $CERT_ARN"
fi

listener_arn() {
  aws elbv2 describe-listeners --load-balancer-arn "$ALB_ARN" \
    --query "Listeners[?Port==\`$1\`].ListenerArn" --output text
}

# --- :8080 -> gateway por HTTPS ---
L8080=$(listener_arn 8080)
if [ -n "$L8080" ] && [ "$L8080" != "None" ]; then
  aws elbv2 modify-listener --listener-arn "$L8080" \
    --protocol HTTPS --port 8080 \
    --certificates CertificateArn="$CERT_ARN" \
    --default-actions Type=forward,TargetGroupArn="$TG_GATEWAY_ARN" >/dev/null
else
  aws elbv2 create-listener --load-balancer-arn "$ALB_ARN" \
    --protocol HTTPS --port 8080 \
    --certificates CertificateArn="$CERT_ARN" \
    --default-actions Type=forward,TargetGroupArn="$TG_GATEWAY_ARN" >/dev/null
fi
echo "Listener HTTPS:8080 -> gateway listo."

# --- :443 -> front por HTTPS ---
L443=$(listener_arn 443)
if [ -n "$L443" ] && [ "$L443" != "None" ]; then
  aws elbv2 modify-listener --listener-arn "$L443" \
    --certificates CertificateArn="$CERT_ARN" \
    --default-actions Type=forward,TargetGroupArn="$TG_FRONT_ARN" >/dev/null
else
  aws elbv2 create-listener --load-balancer-arn "$ALB_ARN" \
    --protocol HTTPS --port 443 \
    --certificates CertificateArn="$CERT_ARN" \
    --default-actions Type=forward,TargetGroupArn="$TG_FRONT_ARN" >/dev/null
fi
echo "Listener HTTPS:443 -> front listo."

# --- :80 -> redirect a https:// (así nadie queda en la versión http de front) ---
L80=$(listener_arn 80)
if [ -n "$L80" ] && [ "$L80" != "None" ]; then
  aws elbv2 modify-listener --listener-arn "$L80" \
    --default-actions 'Type=redirect,RedirectConfig={Protocol=HTTPS,Port=443,StatusCode=HTTP_301}' >/dev/null
  echo "Listener HTTP:80 ahora redirige a HTTPS:443."
fi

GATEWAY_PUBLIC_URL="https://${ALB_DNS}:8080"
FRONT_PUBLIC_URL="https://${ALB_DNS}"
echo "$GATEWAY_PUBLIC_URL" > "$STATE_DIR/gateway_public_url.txt"
echo "$FRONT_PUBLIC_URL" > "$STATE_DIR/front_public_url.txt"

cat <<EOF

============================================================
Listo. Gateway ahora sirve HTTPS en: $GATEWAY_PUBLIC_URL
       Front ahora sirve HTTPS en:   $FRONT_PUBLIC_URL
============================================================

Siguiente paso (manual, en console.cloud.google.com):

1. APIs & Services -> OAuth consent screen
   - User Type: External
   - Scopes: openid, .../auth/userinfo.email, .../auth/userinfo.profile
   - Test users: agrega la(s) cuenta(s) Gmail que van a hacer login

2. APIs & Services -> Credentials -> Create credentials -> OAuth client ID
   - Application type: Web application
   - Authorized redirect URIs, agrega EXACTO:
     ${GATEWAY_PUBLIC_URL}/auth/callback
   - Copia el Client ID y el Client secret que te muestra

3. Corre con esos valores (16 también actualiza FRONT_BASE_URL del gateway
   a https://, necesario para su CORS):
   export GOOGLE_CLIENT_ID="..."
   export GOOGLE_CLIENT_SECRET="..."
   ./16-update-gateway-oauth.sh
   ./17-rebuild-front-https.sh
EOF
