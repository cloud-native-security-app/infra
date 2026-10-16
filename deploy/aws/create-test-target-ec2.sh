#!/usr/bin/env bash
# Levanta una EC2 simple (Amazon Linux 2023, t3.micro) lista para usarse como
# objetivo de prueba del flujo de credenciales de red + escaneo:
#   - nmap instalado (si no, ms-nmap falla con ToolNotAvailable, ver
#     nmap-service/src/scanner.rs).
#   - Login SSH por contraseña habilitado (las AMIs de AWS lo traen
#     deshabilitado por defecto; ms-nmap solo soporta authenticate_password,
#     no llave pública — ver nmap-service/src/ssh.rs).
#   - Security group propio con el puerto 22 abierto a 0.0.0.0/0 (Fargate
#     usa IP pública dinámica de la VPC default, no hay una IP fija a la que
#     restringir el origen para esta prueba).
# No usa key pair de EC2: como el login es por contraseña, no hace falta.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/00-env.sh"

TARGET_SG_NAME="${PROJECT}-test-target-sg"
INSTANCE_NAME="${PROJECT}-test-target"
SSH_USER="ec2-user"
SSH_PASSWORD="$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c 20)"

VPC_ID=$(cat "$STATE_DIR/vpc_id.txt" 2>/dev/null || \
  aws ec2 describe-vpcs --filters Name=isDefault,Values=true \
    --query 'Vpcs[0].VpcId' --output text)

if TARGET_SG_ID=$(aws ec2 describe-security-groups \
    --filters Name=group-name,Values="$TARGET_SG_NAME" Name=vpc-id,Values="$VPC_ID" \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null) && [ "$TARGET_SG_ID" != "None" ]; then
  echo "Security group $TARGET_SG_NAME ya existe: $TARGET_SG_ID"
else
  TARGET_SG_ID=$(aws ec2 create-security-group \
    --group-name "$TARGET_SG_NAME" \
    --description "SSH de prueba para el objetivo de escaneo de ${PROJECT}" \
    --vpc-id "$VPC_ID" --query 'GroupId' --output text)
  aws ec2 authorize-security-group-ingress --group-id "$TARGET_SG_ID" \
    --protocol tcp --port 22 --cidr 0.0.0.0/0 >/dev/null
  echo "Security group $TARGET_SG_NAME creado: $TARGET_SG_ID"
fi
echo "$TARGET_SG_ID" > "$STATE_DIR/test_target_sg_id.txt"

SUBNET_ID=$(aws ec2 describe-subnets \
  --filters Name=vpc-id,Values="$VPC_ID" Name=default-for-az,Values=true \
  --query 'Subnets[0].SubnetId' --output text)

AMI_ID=$(aws ssm get-parameters \
  --names /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --query 'Parameters[0].Value' --output text --region "$AWS_REGION")

USER_DATA=$(cat <<EOF
#!/bin/bash
dnf install -y nmap
echo "${SSH_USER}:${SSH_PASSWORD}" | chpasswd
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
systemctl restart sshd
EOF
)

INSTANCE_ID=$(aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type t3.micro \
  --subnet-id "$SUBNET_ID" \
  --security-group-ids "$TARGET_SG_ID" \
  --associate-public-ip-address \
  --user-data "$USER_DATA" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${INSTANCE_NAME}}]" \
  --query 'Instances[0].InstanceId' --output text)
echo "$INSTANCE_ID" > "$STATE_DIR/test_target_instance_id.txt"
echo "Instancia $INSTANCE_ID creándose, esperando IP pública..."

aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"
INSTANCE_INFO=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].{public:PublicIpAddress,private:PrivateIpAddress}')
PUBLIC_IP=$(echo "$INSTANCE_INFO" | jq -r '.public')
PRIVATE_IP=$(echo "$INSTANCE_INFO" | jq -r '.private')
echo "$PUBLIC_IP" > "$STATE_DIR/test_target_public_ip.txt"
echo "$PRIVATE_IP" > "$STATE_DIR/test_target_private_ip.txt"

cat <<SUMMARY

============================================================
Objetivo de prueba listo (puede tardar ~1 min más en aceptar
SSH mientras corre el user-data: instala nmap y habilita el
login por contraseña).

  IP privada:     ${PRIVATE_IP}
  IP pública:     ${PUBLIC_IP}
  Usuario SSH:    ${SSH_USER}
  Contraseña SSH: ${SSH_PASSWORD}

Usá la IP PRIVADA en el formulario "Credenciales de red" de front, no la
pública: ms-nmap se conecta por SSH a esta IP y ejecuta nmap apuntando a
esa MISMA IP (es un auto-escaneo, no un escaneo remoto) -- contra la IP
pública, el tráfico de vuelta a sí misma no hace el "hairpin" NAT que
hace falta en AWS, y nmap siempre la ve "caída". ms-nmap vive en la
misma VPC, así que llega perfecto a la privada.

  IP o rango del objetivo: ${PRIVATE_IP}/32
  Usuario de red:          ${SSH_USER}
  Credencial SSH:          ${SSH_PASSWORD}
  Tiene privilegios sudo:  sin marcar (sudo -n de esta AMI pide
                           contraseña; para probar con sudo,
                           configurá NOPASSWD en el sudoers vos)

(La IP pública sirve solo si querés entrar vos mismo por SSH desde tu
máquina para inspeccionar la instancia -- nunca para el escaneo.)

Para borrar esta instancia cuando termines:
  aws ec2 terminate-instances --instance-ids ${INSTANCE_ID}
  aws ec2 delete-security-group --group-id ${TARGET_SG_ID}
============================================================
SUMMARY
