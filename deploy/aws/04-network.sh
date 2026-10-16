#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/00-env.sh"

VPC_ID=$(aws ec2 describe-vpcs \
  --filters Name=isDefault,Values=true \
  --query 'Vpcs[0].VpcId' --output text)
echo "$VPC_ID" > "$STATE_DIR/vpc_id.txt"
echo "VPC default: $VPC_ID"

# Subnets públicas de la VPC default (todas lo son: MapPublicIpOnLaunch=true).
SUBNET_IDS=$(aws ec2 describe-subnets \
  --filters Name=vpc-id,Values="$VPC_ID" Name=default-for-az,Values=true \
  --query 'Subnets[].SubnetId' --output text | tr '\t' ',')
echo "$SUBNET_IDS" > "$STATE_DIR/subnet_ids.txt"
echo "Subnets: $SUBNET_IDS"

# --- alb-sg: solo el ALB recibe tráfico público en 80/8080 ---
if ALB_SG_ID=$(aws ec2 describe-security-groups \
    --filters Name=group-name,Values="$ALB_SG_NAME" Name=vpc-id,Values="$VPC_ID" \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null) && [ "$ALB_SG_ID" != "None" ]; then
  echo "Security group $ALB_SG_NAME ya existe: $ALB_SG_ID"
else
  ALB_SG_ID=$(aws ec2 create-security-group \
    --group-name "$ALB_SG_NAME" \
    --description "Ingreso publico al ALB de ${PROJECT}" \
    --vpc-id "$VPC_ID" --query 'GroupId' --output text)
  aws ec2 authorize-security-group-ingress --group-id "$ALB_SG_ID" \
    --protocol tcp --port 80 --cidr 0.0.0.0/0 >/dev/null
  aws ec2 authorize-security-group-ingress --group-id "$ALB_SG_ID" \
    --protocol tcp --port 8080 --cidr 0.0.0.0/0 >/dev/null
  echo "Security group $ALB_SG_NAME creado: $ALB_SG_ID"
fi
# 443 -> front por HTTPS (lo usa 15-enable-https-gateway.sh). Fuera del
# bloque de creación para que también se agregue a un SG ya existente;
# `|| true` porque falla con InvalidPermission.Duplicate si ya estaba.
aws ec2 authorize-security-group-ingress --group-id "$ALB_SG_ID" \
  --protocol tcp --port 443 --cidr 0.0.0.0/0 >/dev/null 2>&1 || true
echo "$ALB_SG_ID" > "$STATE_DIR/alb_sg_id.txt"

# --- internal-sg: todas las tasks ECS (postgres/mongo/rabbitmq/user-service/
#     nmap-service/gateway/front) ---
if INTERNAL_SG_ID=$(aws ec2 describe-security-groups \
    --filters Name=group-name,Values="$INTERNAL_SG_NAME" Name=vpc-id,Values="$VPC_ID" \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null) && [ "$INTERNAL_SG_ID" != "None" ]; then
  echo "Security group $INTERNAL_SG_NAME ya existe: $INTERNAL_SG_ID"
else
  INTERNAL_SG_ID=$(aws ec2 create-security-group \
    --group-name "$INTERNAL_SG_NAME" \
    --description "Trafico interno entre tasks de ${PROJECT}" \
    --vpc-id "$VPC_ID" --query 'GroupId' --output text)

  # Self-referencing: cualquier task del SG puede hablarle a cualquier otra
  # en los puertos que exponen postgres/mongo/rabbitmq/user-service/gateway.
  for PORT in 5432 27017 5672 5671 15672 8080; do
    aws ec2 authorize-security-group-ingress --group-id "$INTERNAL_SG_ID" \
      --protocol tcp --port "$PORT" --source-group "$INTERNAL_SG_ID" >/dev/null
  done

  # El ALB (SG distinto) necesita llegar a front/gateway en su puerto de
  # contenedor 8080. Sin esta regla el ALB marca los targets como unhealthy
  # aunque las tasks estén corriendo bien.
  aws ec2 authorize-security-group-ingress --group-id "$INTERNAL_SG_ID" \
    --protocol tcp --port 8080 --source-group "$ALB_SG_ID" >/dev/null

  echo "Security group $INTERNAL_SG_NAME creado: $INTERNAL_SG_ID"
fi
echo "$INTERNAL_SG_ID" > "$STATE_DIR/internal_sg_id.txt"

echo "alb-sg=$ALB_SG_ID internal-sg=$INTERNAL_SG_ID"
