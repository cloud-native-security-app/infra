#!/usr/bin/env bash
# Creates (or reuses) a disposable EC2 instance used as the target of end-to-end scan tests.
# It lives outside Terraform on purpose: it is a throwaway lab target with a password login,
# not part of the platform, and it must be easy to create and destroy on demand.
#
# Usage: scripts/create-test-target.sh [--destroy] [--dry-run]
#   (default)  create the target, or reuse the existing one (start it if stopped).
#   --destroy  terminate the instance (waits for terminated) and delete the target SG.
#   --dry-run  validate credentials, read state and print the planned actions; no mutating call.
#   env: PROJECT (default security-app), AWS_PROFILE (default learnerlab),
#        AWS_REGION (default us-east-1).
#
# Network: default VPC, public IP (needed for dnf to reach the internet without a NAT).
# SSH (tcp/22) is allowed ONLY from the Terraform internal security group
# (${PROJECT}-internal-sg), never from 0.0.0.0/0: scans use the PRIVATE IP and run from the
# nmap-service tasks, which sit in that SG inside the same VPC.
# Stdout carries the summary; the last line is the instance id. Nothing is stored on disk.
set -euo pipefail

PROJECT="${PROJECT:-security-app}"
AWS_PROFILE="${AWS_PROFILE:-learnerlab}"
AWS_REGION="${AWS_REGION:-us-east-1}"
TARGET_SG_NAME="${PROJECT}-test-target-sg"
INTERNAL_SG_NAME="${PROJECT}-internal-sg"
INSTANCE_NAME="${PROJECT}-test-target"
SSH_USER="ec2-user"
AMI_PARAM="/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
DESTROY=0
DRY_RUN=0

for arg in "$@"; do
  case "$arg" in
    --destroy) DESTROY=1 ;;
    --dry-run) DRY_RUN=1 ;;
    *) echo "unknown argument: $arg (usage: $0 [--destroy] [--dry-run])" >&2; exit 2 ;;
  esac
done

log() { echo "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

# aws-cli v1 ignores AWS_REGION, so profile and region are always explicit.
awsr() { aws --profile "$AWS_PROFILE" --region "$AWS_REGION" "$@"; }
# mutate: runs a mutating aws call, or only prints it under --dry-run.
mutate() {
  if [ "$DRY_RUN" -eq 1 ]; then log "DRY-RUN: aws ec2 $*"; else awsr ec2 "$@"; fi
}
# none_if_empty: AWS CLI prints "None" for a missing value.
none_if_empty() { [ "$1" = "None" ] && echo "" || echo "$1"; }

if ! awsr sts get-caller-identity --query Account --output text >/dev/null 2>&1; then
  die "credentials in profile '$AWS_PROFILE' are invalid or expired; refresh the Learner Lab credentials (AWS Details -> AWS CLI) into ~/.aws/credentials"
fi

VPC_ID="$(awsr ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)"
VPC_ID="$(none_if_empty "$VPC_ID")"
[ -n "$VPC_ID" ] || die "no default VPC in $AWS_REGION"

sg_id() {
  none_if_empty "$(awsr ec2 describe-security-groups \
    --filters "Name=group-name,Values=$1" "Name=vpc-id,Values=$VPC_ID" \
    --query 'SecurityGroups[0].GroupId' --output text)"
}

# Non-terminated instance tagged Name=${INSTANCE_NAME}: "<id> <state>" or empty.
existing="$(awsr ec2 describe-instances \
  --filters "Name=tag:Name,Values=$INSTANCE_NAME" \
            "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[].Instances[].[InstanceId,State.Name]' --output text | head -n1)"
INSTANCE_ID=""
STATE=""
if [ -n "$existing" ]; then read -r INSTANCE_ID STATE <<<"$existing"; fi

TARGET_SG_ID="$(sg_id "$TARGET_SG_NAME")"

if [ "$DESTROY" -eq 1 ]; then
  if [ -n "$INSTANCE_ID" ]; then
    log "terminating $INSTANCE_ID ..."
    mutate terminate-instances --instance-ids "$INSTANCE_ID" --output text --query 'TerminatingInstances[0].InstanceId' >/dev/null
    if [ "$DRY_RUN" -eq 1 ]; then log "DRY-RUN: aws ec2 wait instance-terminated --instance-ids $INSTANCE_ID"; else awsr ec2 wait instance-terminated --instance-ids "$INSTANCE_ID"; fi
  else
    log "no instance tagged $INSTANCE_NAME"
  fi
  if [ -n "$TARGET_SG_ID" ]; then
    log "deleting security group $TARGET_SG_NAME ($TARGET_SG_ID) ..."
    mutate delete-security-group --group-id "$TARGET_SG_ID"
  else
    log "no security group $TARGET_SG_NAME"
  fi
  if [ "$DRY_RUN" -eq 1 ]; then log "dry run: nothing was changed"; else log "destroyed"; fi
  exit 0
fi

# Create / reuse path: the internal SG comes from the Terraform stack and must exist first.
INTERNAL_SG_ID="$(sg_id "$INTERNAL_SG_NAME")"
[ -n "$INTERNAL_SG_ID" ] || die "security group $INTERNAL_SG_NAME not found in $VPC_ID; apply the Terraform stack first"

CREATED=0
PASSWORD=""
case "$STATE" in
  running) log "reusing running instance $INSTANCE_ID" ;;
  pending) log "instance $INSTANCE_ID is pending; waiting" ;;
  stopping)
    log "instance $INSTANCE_ID is stopping; waiting, then starting it"
    if [ "$DRY_RUN" -eq 0 ]; then awsr ec2 wait instance-stopped --instance-ids "$INSTANCE_ID"; fi
    mutate start-instances --instance-ids "$INSTANCE_ID" >/dev/null ;;
  stopped)
    log "starting stopped instance $INSTANCE_ID"
    mutate start-instances --instance-ids "$INSTANCE_ID" >/dev/null ;;
  *)
    if [ -z "$TARGET_SG_ID" ]; then
      log "creating security group $TARGET_SG_NAME ..."
      if [ "$DRY_RUN" -eq 1 ]; then
        TARGET_SG_ID="<new-target-sg>"
      else
        TARGET_SG_ID="$(awsr ec2 create-security-group --group-name "$TARGET_SG_NAME" \
          --description "SSH from the internal SG to the scan test target of ${PROJECT}" \
          --vpc-id "$VPC_ID" --query 'GroupId' --output text)"
      fi
      # Only the internal SG may reach tcp/22; never a CIDR.
      mutate authorize-security-group-ingress --group-id "$TARGET_SG_ID" \
        --protocol tcp --port 22 --source-group "$INTERNAL_SG_ID" >/dev/null
    else
      log "security group $TARGET_SG_NAME already exists: $TARGET_SG_ID"
    fi
    SUBNET_ID="$(none_if_empty "$(awsr ec2 describe-subnets \
      --filters "Name=vpc-id,Values=$VPC_ID" Name=default-for-az,Values=true \
      --query 'Subnets[0].SubnetId' --output text)")"
    [ -n "$SUBNET_ID" ] || die "no default-for-az subnet in $VPC_ID"
    AMI_ID="$(awsr ssm get-parameters --names "$AMI_PARAM" --query 'Parameters[0].Value' --output text)"

    # Random 20-char alphanumeric password. cut (not head) avoids SIGPIPE under pipefail.
    PASSWORD="$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | cut -c1-20)"
    [ "${#PASSWORD}" -eq 20 ] || die "could not generate the password"
    # AL2023 ships /etc/ssh/sshd_config.d/*.conf (e.g. 50-cloud-init.conf with
    # PasswordAuthentication no); sshd keeps the first value it reads, so a 00- drop-in wins
    # and the existing overrides are rewritten as well.
    USER_DATA="$(cat <<UD
#!/bin/bash
dnf install -y nmap
echo "${SSH_USER}:${PASSWORD}" | chpasswd
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
for f in /etc/ssh/sshd_config.d/*.conf; do
  [ -e "\$f" ] && sed -i 's/^\s*#\?\s*PasswordAuthentication.*/PasswordAuthentication yes/' "\$f"
done
echo 'PasswordAuthentication yes' > /etc/ssh/sshd_config.d/00-password-auth.conf
systemctl restart sshd
UD
)"
    log "launching t3.micro ($AMI_ID) ..."
    if [ "$DRY_RUN" -eq 1 ]; then
      log "DRY-RUN: aws ec2 run-instances --image-id $AMI_ID --instance-type t3.micro --subnet-id $SUBNET_ID --security-group-ids $TARGET_SG_ID --associate-public-ip-address (tag Name=$INSTANCE_NAME)"
      log "dry run: nothing was changed"
      exit 0
    fi
    INSTANCE_ID="$(awsr ec2 run-instances --image-id "$AMI_ID" --instance-type t3.micro \
      --subnet-id "$SUBNET_ID" --security-group-ids "$TARGET_SG_ID" \
      --associate-public-ip-address --user-data "$USER_DATA" \
      --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${INSTANCE_NAME}}]" \
      --query 'Instances[0].InstanceId' --output text)"
    CREATED=1 ;;
esac

if [ "$DRY_RUN" -eq 1 ]; then log "dry run: nothing was changed"; exit 0; fi

awsr ec2 wait instance-running --instance-ids "$INSTANCE_ID"
read -r PRIVATE_IP PUBLIC_IP < <(awsr ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].[PrivateIpAddress,PublicIpAddress]' --output text)

{
  echo
  echo "Scan test target ready: $INSTANCE_ID"
  echo
  echo "Front form \"Credenciales de red\":"
  echo "  Target:   ${PRIVATE_IP}/32"
  echo "  User:     ${SSH_USER}"
  if [ "$CREATED" -eq 1 ]; then
    # Printed once, only now. Acceptable: disposable lab target, SSH reachable only from the
    # internal SG, destroyed with --destroy.
    echo "  Password: ${PASSWORD}"
  else
    echo "  Password: not shown again (it was printed when the instance was created)."
    echo "            To reset it: run with --destroy, then run this script again."
  fi
  echo "  Sudo:     unchecked (sudo -n asks for a password on this AMI)"
  echo
  echo "Use the PRIVATE IP, not the public one (${PUBLIC_IP}): nmap-service SSHes into the target"
  echo "and scans that same IP (a self-scan), and AWS gives no hairpin NAT for a public IP."
  echo "sshd may take ~1-2 min to accept the password while user-data installs nmap."
  echo "When done: scripts/create-test-target.sh --destroy"
  echo "$INSTANCE_ID"
}
