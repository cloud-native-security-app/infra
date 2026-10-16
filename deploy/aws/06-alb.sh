#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/00-env.sh"

VPC_ID=$(cat "$STATE_DIR/vpc_id.txt")
ALB_SG_ID=$(cat "$STATE_DIR/alb_sg_id.txt")
SUBNET_IDS=$(cat "$STATE_DIR/subnet_ids.txt")

if ALB_ARN=$(aws elbv2 describe-load-balancers --names "$ALB_NAME" \
    --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null) && [ "$ALB_ARN" != "None" ]; then
  echo "ALB $ALB_NAME ya existe: $ALB_ARN"
else
  ALB_ARN=$(aws elbv2 create-load-balancer \
    --name "$ALB_NAME" \
    --type application --scheme internet-facing \
    --subnets $(echo "$SUBNET_IDS" | tr ',' ' ') \
    --security-groups "$ALB_SG_ID" \
    --query 'LoadBalancers[0].LoadBalancerArn' --output text)
  echo "ALB $ALB_NAME creado: $ALB_ARN"
fi
echo "$ALB_ARN" > "$STATE_DIR/alb_arn.txt"

ALB_DNS=$(aws elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN" \
  --query 'LoadBalancers[0].DNSName' --output text)
echo "$ALB_DNS" > "$STATE_DIR/alb_dns.txt"
echo "ALB DNS: $ALB_DNS"

# Target group de front (puerto de contenedor 8080; awsvpc -> target-type ip)
if TG_FRONT_ARN=$(aws elbv2 describe-target-groups --names "${PROJECT}-front-tg" \
    --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null) && [ "$TG_FRONT_ARN" != "None" ]; then
  echo "Target group front ya existe: $TG_FRONT_ARN"
else
  TG_FRONT_ARN=$(aws elbv2 create-target-group \
    --name "${PROJECT}-front-tg" \
    --protocol HTTP --port 8080 --vpc-id "$VPC_ID" \
    --target-type ip \
    --health-check-path "/" --health-check-interval-seconds 15 \
    --healthy-threshold-count 2 --unhealthy-threshold-count 3 \
    --query 'TargetGroups[0].TargetGroupArn' --output text)
  echo "Target group front creado: $TG_FRONT_ARN"
fi
echo "$TG_FRONT_ARN" > "$STATE_DIR/tg_front_arn.txt"

# Target group de gateway
if TG_GATEWAY_ARN=$(aws elbv2 describe-target-groups --names "${PROJECT}-gateway-tg" \
    --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null) && [ "$TG_GATEWAY_ARN" != "None" ]; then
  echo "Target group gateway ya existe: $TG_GATEWAY_ARN"
else
  TG_GATEWAY_ARN=$(aws elbv2 create-target-group \
    --name "${PROJECT}-gateway-tg" \
    --protocol HTTP --port 8080 --vpc-id "$VPC_ID" \
    --target-type ip \
    --health-check-path "/health" --health-check-interval-seconds 15 \
    --healthy-threshold-count 2 --unhealthy-threshold-count 3 \
    --query 'TargetGroups[0].TargetGroupArn' --output text)
  echo "Target group gateway creado: $TG_GATEWAY_ARN"
fi
echo "$TG_GATEWAY_ARN" > "$STATE_DIR/tg_gateway_arn.txt"

# Listeners (idempotente: si ya existe uno en ese puerto, no se duplica)
EXISTING_PORTS=$(aws elbv2 describe-listeners --load-balancer-arn "$ALB_ARN" \
  --query 'Listeners[].Port' --output text)

if ! echo "$EXISTING_PORTS" | grep -qw 80; then
  aws elbv2 create-listener --load-balancer-arn "$ALB_ARN" \
    --protocol HTTP --port 80 \
    --default-actions Type=forward,TargetGroupArn="$TG_FRONT_ARN" >/dev/null
  echo "Listener 80 -> front creado."
fi

if ! echo "$EXISTING_PORTS" | grep -qw 8080; then
  aws elbv2 create-listener --load-balancer-arn "$ALB_ARN" \
    --protocol HTTP --port 8080 \
    --default-actions Type=forward,TargetGroupArn="$TG_GATEWAY_ARN" >/dev/null
  echo "Listener 8080 -> gateway creado."
fi

echo
echo "ALB listo. DNS público: $ALB_DNS"
echo "  http://${ALB_DNS}/        -> front (503 hasta que el service exista, ver 13-deploy-front.sh)"
echo "  http://${ALB_DNS}:8080/   -> gateway (503 hasta que el service exista, ver 12-deploy-tier2-gateway.sh)"
