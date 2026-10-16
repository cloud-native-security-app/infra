#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/00-env.sh"

# 5 repos privados. postgres/mongo NO están aquí: usan directamente los
# espejos públicos definidos en 00-env.sh (IMG_POSTGRES/IMG_MONGO).
REPOS=(user-service nmap-service gateway front rabbitmq-custom)

for repo in "${REPOS[@]}"; do
  if aws ecr describe-repositories --repository-names "${PROJECT}/${repo}" \
      --region "$AWS_REGION" >/dev/null 2>&1; then
    echo "Repo ${PROJECT}/${repo} ya existe."
  else
    aws ecr create-repository \
      --repository-name "${PROJECT}/${repo}" \
      --image-scanning-configuration scanOnPush=true \
      --image-tag-mutability MUTABLE \
      --region "$AWS_REGION" >/dev/null
    echo "Repo ${PROJECT}/${repo} creado."
  fi
done

aws ecr get-login-password --region "$AWS_REGION" | \
  docker login --username AWS --password-stdin "$ECR_REGISTRY"

echo "Repos ECR listos en $ECR_REGISTRY"
