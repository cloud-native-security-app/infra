#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/00-env.sh"

# AWS Academy Learner Lab no permite crear roles IAM nuevos (sin
# iam:CreateRole) — se reutiliza el rol preexistente de la cuenta,
# `LabRole` ($EXEC_ROLE_NAME en 00-env.sh), en vez de crear un
# ecsTaskExecutionRole propio. Si no usas Academy y sí tienes permisos de
# IAM, apunta $EXEC_ROLE_NAME a un rol que crees a mano (trust policy para
# `ecs-tasks.amazonaws.com`, con la policy `AmazonECSTaskExecutionRolePolicy`
# adjunta) y este mismo script lo resuelve igual.
aws iam get-role --role-name "$EXEC_ROLE_NAME" \
  --query 'Role.Arn' --output text > "$STATE_DIR/exec_role_arn.txt"

echo "Reutilizando rol existente: $(cat "$STATE_DIR/exec_role_arn.txt")"
