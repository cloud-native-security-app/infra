#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/00-env.sh"

# El namespace de Cloud Map para Service Connect se pasa como
# --service-connect-defaults en la CREACIÓN del cluster, en vez de crearlo
# nosotros a mano con `aws servicediscovery create-http-namespace`: en AWS
# Academy la identidad del estudiante (rol `voclabs`) no tiene el permiso
# servicediscovery:CreateHttpNamespace, pero ECS sí puede crear el namespace
# por su cuenta (vía su service-linked role AWSServiceRoleForECS) cuando se
# lo pasas así. --service-connect-defaults solo se puede fijar en la
# creación del cluster, no después — si el cluster ya existe sin él
# (de un intento anterior), se borra y se recrea.
EXISTING_NS=$(aws ecs describe-clusters --clusters "$CLUSTER_NAME" \
  --query 'clusters[0].serviceConnectDefaults.namespace' --output text 2>/dev/null || echo "None")

if [ "$EXISTING_NS" = "$NAMESPACE_NAME" ]; then
  echo "Cluster $CLUSTER_NAME ya existe con namespace Service Connect $NAMESPACE_NAME."
else
  if [ "$EXISTING_NS" != "None" ] && [ -n "$EXISTING_NS" ]; then
    echo "Cluster $CLUSTER_NAME existe sin el namespace correcto — recreando..."
    aws ecs delete-cluster --cluster "$CLUSTER_NAME" >/dev/null
  fi
  aws ecs create-cluster --cluster-name "$CLUSTER_NAME" \
    --capacity-providers FARGATE \
    --default-capacity-provider-strategy capacityProvider=FARGATE,weight=1 \
    --service-connect-defaults namespace="$NAMESPACE_NAME" >/dev/null
  echo "Cluster $CLUSTER_NAME creado con namespace Service Connect $NAMESPACE_NAME."
fi

# Resolver el ID del namespace (ECS ya lo creó arriba) solo para guardarlo
# en el estado — es de solo lectura (list-namespaces), no requiere permiso
# de create. Si tarda unos segundos en aparecer o el permiso de lectura
# también estuviera restringido, no es bloqueante: los pasos 10-13
# referencian el namespace por NOMBRE, no por ID; solo 99-cleanup.sh lo usa,
# y ya tolera que falte.
NAMESPACE_ID=$(aws servicediscovery list-namespaces \
  --query "Namespaces[?Name=='${NAMESPACE_NAME}'].Id" --output text 2>/dev/null || true)
if [ -n "$NAMESPACE_ID" ] && [ "$NAMESPACE_ID" != "None" ]; then
  echo "$NAMESPACE_ID" > "$STATE_DIR/namespace_id.txt"
  echo "Namespace Service Connect: $NAMESPACE_NAME ($NAMESPACE_ID)"
else
  echo "Aviso: namespace aún no resoluble por list-namespaces (no bloqueante, se usa por nombre en los pasos siguientes)."
fi

# Log groups, uno por servicio
for svc in postgres mongo rabbitmq user-service nmap-service gateway front; do
  aws logs create-log-group --log-group-name "${LOG_PREFIX}/${svc}" 2>/dev/null || true
  aws logs put-retention-policy --log-group-name "${LOG_PREFIX}/${svc}" --retention-in-days 3
done

echo "Cluster + namespace + log groups listos."
