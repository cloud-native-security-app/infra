#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/00-env.sh"

command -v aws >/dev/null || { echo "Falta AWS CLI v2 instalado" >&2; exit 1; }
command -v docker >/dev/null || { echo "Falta Docker instalado" >&2; exit 1; }
aws sts get-caller-identity >/dev/null || { echo "Corre 'aws configure' primero (credenciales inválidas)" >&2; exit 1; }

echo "Cuenta AWS: $AWS_ACCOUNT_ID"
echo "Región: $AWS_REGION"
echo "Registry ECR: $ECR_REGISTRY"
echo "OK — prerrequisitos satisfechos."
echo
echo "Notas:"
echo "- Necesitas permisos de administrador o al menos: ECS, ECR, EC2 (SGs/ALB),"
echo "  IAM (crear rol), Cloud Map / Service Discovery, CloudWatch Logs."
echo "- El límite de vCPU de Fargate por defecto de la cuenta alcanza para las"
echo "  7 tasks pequeñas de este despliegue; si algún 'create-service' falla"
echo "  por límite de servicio, pide un aumento en Service Quotas."
