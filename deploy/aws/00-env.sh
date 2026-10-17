#!/usr/bin/env bash
# Variables comunes a todos los scripts de deploy/aws/. Se hace `source` de
# este archivo al principio de cada uno de los demás.
set -euo pipefail

export AWS_REGION="${AWS_REGION:-us-east-1}"
export AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
export PROJECT="security-app"

# -v2: el nombre original (security-app-cluster) quedó bloqueado por la
# idempotencia de CreateCluster tras un intento previo con argumentos
# distintos (sin --service-connect-defaults) — AWS rechaza recrearlo bajo
# el mismo nombre por un rato aunque el cluster viejo ya esté borrado. Un
# nombre nuevo evita el choque sin tener que esperar.
export CLUSTER_NAME="${PROJECT}-cluster-v2"
export NAMESPACE_NAME="${PROJECT}.local"
export ALB_NAME="${PROJECT}-alb"
export ALB_SG_NAME="${PROJECT}-alb-sg"
export INTERNAL_SG_NAME="${PROJECT}-internal-sg"
# AWS Academy Learner Lab no permite crear roles IAM nuevos, así que se
# reutiliza el rol preexistente de la cuenta (`LabRole`) en vez de crear un
# ecsTaskExecutionRole propio — ver 03-iam-roles.sh. Si despliegas desde una
# cuenta propia con permisos de IAM, cambia esto por el nombre del rol que
# quieras usar (o restaura la lógica de create-role en 03-iam-roles.sh).
export EXEC_ROLE_NAME="LabRole"
export LOG_PREFIX="/ecs/${PROJECT}"

export ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
export IMG_USER_SERVICE="${ECR_REGISTRY}/${PROJECT}/user-service:latest"
export IMG_NMAP_SERVICE="${ECR_REGISTRY}/${PROJECT}/nmap-service:latest"
export IMG_GATEWAY="${ECR_REGISTRY}/${PROJECT}/gateway:latest"
export IMG_FRONT="${ECR_REGISTRY}/${PROJECT}/front:latest"
export IMG_RABBITMQ="${ECR_REGISTRY}/${PROJECT}/rabbitmq-custom:latest"
# Espejos públicos de ECR Public Gallery: evitan el rate limit de pulls
# anónimos de Docker Hub en cada arranque de tasks Fargate. No requieren
# repo propio ni login.
export IMG_POSTGRES="public.ecr.aws/docker/library/postgres:16-alpine"
export IMG_MONGO="public.ecr.aws/docker/library/mongo:7"

# Git Bash en Windows (MSYS) reescribe cualquier argumento que empiece con
# `/` al pasárselo a un .exe nativo (aws.exe, docker.exe): `/ecs/security-app/x`
# llega como `C:/Program Files/Git/ecs/security-app/x`, y el `-subj "/CN=..."`
# de openssl igual. Se desactiva esa conversión y, a cambio, las rutas propias
# (STATE_DIR/SERVICES_ROOT) se expresan en formato `C:/...`, que entienden tanto
# bash como los .exe nativos. En Linux/macOS no existe `cygpath` y esto no
# cambia nada.
export MSYS_NO_PATHCONV=1
to_native_path() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi
}

# Estado intermedio entre scripts (IDs/ARNs de recursos creados). Reemplaza
# de forma manual y explícita lo que Terraform haría con su state file.
export STATE_DIR="$(to_native_path "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.state")"
mkdir -p "$STATE_DIR"

# Carpeta que contiene los repos de servicios (user-service, nmap-service,
# gateway, front, broker), hermanos de `infra`: deploy/aws/ está 3 niveles por
# debajo. Se puede sobrescribir exportando SERVICES_ROOT.
export SERVICES_ROOT="${SERVICES_ROOT:-$(to_native_path "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)")}"

# URL pública de front: http:// hasta que 15-enable-https-gateway.sh habilita
# HTTPS en el ALB y guarda la versión https:// en front_public_url.txt.
front_public_url() {
  if [ -f "$STATE_DIR/front_public_url.txt" ]; then
    cat "$STATE_DIR/front_public_url.txt"
  else
    echo "http://$(cat "$STATE_DIR/alb_dns.txt")"
  fi
}

# Credenciales OAuth de Google: 16-update-gateway-oauth.sh las guarda en
# .state/google_oauth.env (ignorado por git) para que 09-register-task-defs.sh
# las vuelva a aplicar al re-registrar gateway — si no, cada re-run de 09
# dejaba a gateway otra vez con "dev-placeholder" (Google: invalid_client).
# Si GOOGLE_CLIENT_ID/SECRET vienen exportados en el shell, ganan sobre el
# archivo.
GOOGLE_OAUTH_FILE="$STATE_DIR/google_oauth.env"
load_google_oauth() {
  if [ -z "${GOOGLE_CLIENT_ID:-}" ] && [ -f "$GOOGLE_OAUTH_FILE" ]; then
    # shellcheck disable=SC1090
    source "$GOOGLE_OAUTH_FILE"
  fi
}
save_google_oauth() {
  printf 'GOOGLE_CLIENT_ID=%q\nGOOGLE_CLIENT_SECRET=%q\n' \
    "$GOOGLE_CLIENT_ID" "$GOOGLE_CLIENT_SECRET" > "$GOOGLE_OAUTH_FILE"
  chmod 600 "$GOOGLE_OAUTH_FILE"
}
# Lee por stdin la task definition ya renderizada de gateway y reemplaza
# GOOGLE_CLIENT_ID/GOOGLE_CLIENT_SECRET por los valores reales. Ambos son el
# mismo literal "dev-placeholder" en el JSON — un sed global los pisaría
# igual a los dos, por eso se apunta cada campo por nombre con jq.
apply_google_oauth() {
  jq --arg cid "$GOOGLE_CLIENT_ID" --arg secret "$GOOGLE_CLIENT_SECRET" \
    '(.containerDefinitions[0].environment[] | select(.name=="GOOGLE_CLIENT_ID") | .value) = $cid
     | (.containerDefinitions[0].environment[] | select(.name=="GOOGLE_CLIENT_SECRET") | .value) = $secret'
}

# create-service si el service no existe (o quedó INACTIVE tras un
# delete-service), update-service con la task definition indicada si ya
# existe — permite re-correr los scripts 10-13 sin que fallen con
# "Creation of service was not idempotent".
#   ensure_service <nombre> <task-def-arn> [args extra de create-service...]
ensure_service() {
  local name="$1" td="$2"; shift 2
  local status
  status=$(aws ecs describe-services --cluster "$CLUSTER_NAME" --services "$name" \
    --query 'services[0].status' --output text 2>/dev/null || echo "None")
  if [ "$status" = "ACTIVE" ]; then
    echo "Servicio $name ya existe — actualizando a $td"
    aws ecs update-service --cluster "$CLUSTER_NAME" --service "$name" \
      --task-definition "$td" --force-new-deployment >/dev/null
  else
    aws ecs create-service --cluster "$CLUSTER_NAME" --service-name "$name" \
      --task-definition "$td" "$@" >/dev/null
    echo "Servicio $name creado."
  fi
}
