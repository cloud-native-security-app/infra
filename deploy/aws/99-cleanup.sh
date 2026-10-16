#!/usr/bin/env bash
# Desmontaje completo, en orden inverso a la creación. Es un script de
# demo/curso: cada borrado lleva su propio `|| true` a propósito, para que
# termine y reporte qué faltó a mano en vez de abortar a mitad y dejar
# recursos huérfanos facturando.
source "$(dirname "${BASH_SOURCE[0]}")/00-env.sh"

for svc in front gateway nmap-service user-service rabbitmq mongo postgres; do
  aws ecs update-service --cluster "$CLUSTER_NAME" --service "$svc" --desired-count 0 >/dev/null 2>&1 || true
done
aws ecs wait services-stable --cluster "$CLUSTER_NAME" \
  --services front gateway nmap-service user-service rabbitmq mongo postgres 2>/dev/null || true

for svc in front gateway nmap-service user-service rabbitmq mongo postgres; do
  aws ecs delete-service --cluster "$CLUSTER_NAME" --service "$svc" --force >/dev/null 2>&1 || true
done

ALB_ARN=$(cat "$STATE_DIR/alb_arn.txt" 2>/dev/null || true)
if [ -n "${ALB_ARN:-}" ]; then
  for l in $(aws elbv2 describe-listeners --load-balancer-arn "$ALB_ARN" --query 'Listeners[].ListenerArn' --output text 2>/dev/null || true); do
    aws elbv2 delete-listener --listener-arn "$l" || true
  done
  aws elbv2 delete-load-balancer --load-balancer-arn "$ALB_ARN" || true
  aws elbv2 wait load-balancers-deleted --load-balancer-arns "$ALB_ARN" 2>/dev/null || true
fi

[ -f "$STATE_DIR/tg_front_arn.txt" ]   && aws elbv2 delete-target-group --target-group-arn "$(cat "$STATE_DIR/tg_front_arn.txt")" 2>/dev/null || true
[ -f "$STATE_DIR/tg_gateway_arn.txt" ] && aws elbv2 delete-target-group --target-group-arn "$(cat "$STATE_DIR/tg_gateway_arn.txt")" 2>/dev/null || true

aws ecs delete-cluster --cluster "$CLUSTER_NAME" >/dev/null 2>&1 || true

NAMESPACE_ID=$(cat "$STATE_DIR/namespace_id.txt" 2>/dev/null || true)
[ -n "${NAMESPACE_ID:-}" ] && aws servicediscovery delete-namespace --id "$NAMESPACE_ID" >/dev/null 2>&1 || true

# Los SGs no se pueden borrar hasta que las ENIs de las tasks se liberen del
# todo (unos segundos después del delete-service).
sleep 20
INTERNAL_SG_ID=$(cat "$STATE_DIR/internal_sg_id.txt" 2>/dev/null || true)
ALB_SG_ID=$(cat "$STATE_DIR/alb_sg_id.txt" 2>/dev/null || true)
[ -n "${INTERNAL_SG_ID:-}" ] && aws ec2 delete-security-group --group-id "$INTERNAL_SG_ID" 2>/dev/null || true
[ -n "${ALB_SG_ID:-}" ]      && aws ec2 delete-security-group --group-id "$ALB_SG_ID" 2>/dev/null || true

for svc in postgres mongo rabbitmq user-service nmap-service gateway front; do
  aws logs delete-log-group --log-group-name "${LOG_PREFIX}/${svc}" 2>/dev/null || true
done

for repo in user-service nmap-service gateway front rabbitmq-custom; do
  aws ecr delete-repository --repository-name "${PROJECT}/${repo}" --force 2>/dev/null || true
done

# $EXEC_ROLE_NAME (LabRole en AWS Academy, ver 00-env.sh/03-iam-roles.sh) es
# un rol PREEXISTENTE que este despliegue nunca creó — no se borra nunca
# acá. Si en tu cuenta sí creaste un rol propio para esto, bórralo a mano.

# Certificado autofirmado de 15-enable-https-gateway.sh (si se corrió). El
# listener HTTPS que lo usaba ya se borró arriba junto con el resto de
# listeners del ALB, así que esto no falla por "certificado en uso".
CERT_ARN=$(cat "$STATE_DIR/gateway_cert_arn.txt" 2>/dev/null || true)
[ -n "${CERT_ARN:-}" ] && aws acm delete-certificate --certificate-arn "$CERT_ARN" 2>/dev/null || true

rm -rf "$STATE_DIR"
echo "Cleanup completo (revisa la consola de AWS si algún recurso quedó pendiente)."
