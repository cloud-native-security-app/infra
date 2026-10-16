#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/00-env.sh"
cd "$REPO_ROOT"

# --- user-service ---
docker build -t "$IMG_USER_SERVICE" ./user-service
docker push "$IMG_USER_SERVICE"

# --- nmap-service ---
# Su Dockerfile hace `COPY --from=tls ca_certificate.pem ...` (ver
# nmap-service/Dockerfile): en docker-compose.yml ese archivo llega por
# bind-mount desde broker/rabbitmq/tls/, pero Fargate no soporta bind-mounts
# de host, así que se hornea en la imagen. `--build-context` (BuildKit) le
# da al Dockerfile acceso a broker/rabbitmq/tls/ como contexto adicional sin
# copiar/duplicar el archivo ni salirse del contexto normal (./nmap-service)
# — mismo mecanismo que usa docker-compose.yml vía `additional_contexts`.
docker build --build-context tls="$REPO_ROOT/broker/rabbitmq/tls" -t "$IMG_NMAP_SERVICE" ./nmap-service
docker push "$IMG_NMAP_SERVICE"

# --- gateway ---
docker build -t "$IMG_GATEWAY" ./gateway
docker push "$IMG_GATEWAY"

# --- rabbitmq-custom (hornea definitions.json/rabbitmq.conf/tls/) ---
docker build -t "$IMG_RABBITMQ" ./broker/rabbitmq
docker push "$IMG_RABBITMQ"

echo "Imágenes core pusheadas: user-service, nmap-service, gateway, rabbitmq-custom"
echo "(front queda pendiente: depende del DNS del ALB, ver 06-alb.sh y 07-build-push-front-image.sh)"
