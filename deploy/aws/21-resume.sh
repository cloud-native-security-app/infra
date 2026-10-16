#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/00-env.sh"

# Reanuda lo pausado por 20-pause.sh, por tiers y esperando cada uno — mismo
# orden que 10-13: gateway no se reconecta solo al broker, así que tiene que
# arrancar con rabbitmq ya estable, y nmap-service/user-service necesitan
# mongo/postgres arriba.

resume_tier() {
  for svc in "$@"; do
    aws ecs update-service --cluster "$CLUSTER_NAME" --service "$svc" \
      --desired-count 1 >/dev/null
  done
  echo "Levantando: $* ..."
  aws ecs wait services-stable --cluster "$CLUSTER_NAME" --services "$@"
}

resume_tier postgres mongo rabbitmq
resume_tier user-service nmap-service
resume_tier gateway
resume_tier front

echo "Reanudado. Front: $(front_public_url)/"
echo "(la base de datos arranca vacía: no hay persistencia entre pausas)"
