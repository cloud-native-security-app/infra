#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/00-env.sh"

# Pausa el despliegue sin destruirlo: escala los 7 services a 0 tasks, así
# Fargate deja de facturar. Se conserva todo lo demás — ALB (y con él su DNS,
# el certificado y el redirect URI registrado en Google), cluster, task
# definitions, imágenes ECR y .state/ — para volver con 21-resume.sh sin
# repetir 15/16 ni tocar Google Cloud Console.
#
# Lo único que sigue facturando es el ALB (~0,0225 USD/h + LCU mínimo). Si
# no se va a usar por días, 99-cleanup.sh lo borra todo (pero al volver hay
# que registrar el redirect URI del ALB nuevo en Google).
#
# No hay persistencia: postgres/mongo/rabbitmq arrancan vacíos al reanudar.

SERVICES=(front gateway nmap-service user-service rabbitmq mongo postgres)

for svc in "${SERVICES[@]}"; do
  aws ecs update-service --cluster "$CLUSTER_NAME" --service "$svc" \
    --desired-count 0 >/dev/null
  echo "$svc -> 0 tasks"
done

echo "Esperando a que se detengan todas las tasks..."
aws ecs wait services-stable --cluster "$CLUSTER_NAME" --services "${SERVICES[@]}"
echo "Pausado. Para reanudar: ./21-resume.sh"
