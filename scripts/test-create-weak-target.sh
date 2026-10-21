#!/usr/bin/env bash
# Offline tests for create-weak-target.sh (deliberately misconfigured lab target): a fake `aws` on PATH logs argv and simulates the
# lookups through FAKE_* env flags. Needs no credentials and no network.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="$SCRIPT_DIR/create-weak-target.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/bin"
# Flags: FAKE_STS_FAIL, FAKE_INTERNAL_SG_MISSING, FAKE_TARGET_SG_EXISTS,
#        FAKE_INSTANCE_STATE (empty = no instance, else pending|running|stopping|stopped).
cat >"$WORK/bin/aws" <<'FAKE'
#!/usr/bin/env bash
a="$*"
echo "${a//$'\n'/\\n}" >>"$FAKE_AWS_LOG"
case "$a" in
  *"sts get-caller-identity"*)
    [ "${FAKE_STS_FAIL:-0}" = "1" ] && { echo "ExpiredToken" >&2; exit 254; }
    echo "123456789012" ;;
  *"describe-vpcs"*) echo "vpc-0123" ;;
  *"describe-security-groups"*)
    case "$a" in
      *"-internal-sg"*) [ "${FAKE_INTERNAL_SG_MISSING:-0}" = "1" ] && echo "None" || echo "sg-internal1" ;;
      *"-weak-target-sg"*) [ "${FAKE_TARGET_SG_EXISTS:-0}" = "1" ] && echo "sg-target1" || echo "None" ;;
    esac ;;
  *"create-security-group"*) echo "sg-target1" ;;
  *"describe-subnets"*) echo "subnet-0abc" ;;
  *"ssm get-parameters"*) echo "ami-al2023test" ;;
  *"describe-instances"*"--instance-ids"*) printf '10.0.1.25\t54.10.20.30\n' ;;
  *"describe-instances"*)
    [ -n "${FAKE_INSTANCE_STATE:-}" ] && printf 'i-existing\t%s\n' "$FAKE_INSTANCE_STATE" ;;
  *"run-instances"*) echo "i-new0001" ;;
esac
exit 0
FAKE
chmod +x "$WORK/bin/aws"

fail=0
err() { echo "FAIL: $*" >&2; fail=1; }
MUTATING='run-instances|start-instances|terminate-instances|create-security-group|authorize-security-group-ingress|delete-security-group'

# run <name> [env...] -- [args...]: stores stdout/stderr/rc/aws log under $WORK/<name>.
run() {
  local name="$1"; shift
  local envs=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  [ "$#" -gt 0 ] && shift
  : >"$WORK/$name.aws"
  set +e
  env PATH="$WORK/bin:$PATH" FAKE_AWS_LOG="$WORK/$name.aws" "${envs[@]}" bash "$TARGET" "$@" \
    >"$WORK/$name.out" 2>"$WORK/$name.err"
  echo $? >"$WORK/$name.rc"
  set -e
}
rc() { cat "$WORK/$1.rc"; }
no_mutation() { ! rg -q "$MUTATING" "$WORK/$1.aws"; }

# --- create path
run create --
[ "$(rc create)" = 0 ] || err "create: exit $(rc create): $(cat "$WORK/create.err")"
rg -q -F "create-security-group --group-name security-app-weak-target-sg" "$WORK/create.aws" || err "create: target SG not created"
for port in 22 21 80 8443; do
  rg -q -F "authorize-security-group-ingress --group-id sg-target1 --protocol tcp --port $port --source-group sg-internal1" "$WORK/create.aws" \
    || err "create: ingress must be tcp/$port from the internal SG id only"
done
[ "$(rg -c -F "authorize-security-group-ingress" "$WORK/create.aws")" = 4 ] || err "create: exactly 4 ingress rules (22, 21, 80, 8443) expected"
rg -q -F "0.0.0.0/0" "$WORK/create.aws" && err "create: 0.0.0.0/0 must never appear in any aws call"
rg -q -F -- "--cidr" "$WORK/create.aws" && err "create: no --cidr ingress allowed"
rg -q -- "--port (-1|0-65535)" "$WORK/create.aws" && err "create: no wide port ranges allowed"
rg -q -- "run-instances.*--image-id ami-al2023test" "$WORK/create.aws" || err "create: AL2023 AMI from SSM not used"
rg -q -- "run-instances.*--instance-type t3.micro" "$WORK/create.aws" || err "create: t3.micro expected"
rg -q -- "run-instances.*--associate-public-ip-address" "$WORK/create.aws" || err "create: public IP flag missing"
rg -q -- "run-instances.*Key=Name,Value=security-app-weak-target" "$WORK/create.aws" || err "create: Name tag missing"
rg -q -- "al2023-ami-kernel-default-x86_64" "$WORK/create.aws" || err "create: AMI SSM parameter name wrong"
rg -q -- "run-instances.*dnf install -y nmap" "$WORK/create.aws" || err "create: user-data must install nmap"
rg -q -- "run-instances.*chpasswd" "$WORK/create.aws" || err "create: user-data must set the password"
rg -q -- "run-instances.*PasswordAuthentication yes" "$WORK/create.aws" || err "create: user-data must enable PasswordAuthentication"
rg -q -- "run-instances.*sshd_config\.d" "$WORK/create.aws" || err "create: user-data must handle sshd_config.d overrides"
rg -q -- "run-instances.*systemctl restart sshd" "$WORK/create.aws" || err "create: user-data must restart sshd"
# deliberate misconfigurations on stock packages
rg -q -- "run-instances.*dnf install -y.* nginx" "$WORK/create.aws" || err "create: user-data must install nginx"
rg -q -- "run-instances.*openssl dhparam -out /etc/nginx/dh1024.pem 1024" "$WORK/create.aws" || err "create: user-data must generate a 1024-bit DH group"
rg -q -- "run-instances.*ssl_dhparam /etc/nginx/dh1024.pem" "$WORK/create.aws" || err "create: nginx must use ssl_dhparam"
rg -q -F "@SECLEVEL=0" "$WORK/create.aws" || err "create: the weak DH group needs @SECLEVEL=0 or nginx refuses to start on AL2023"
rg -q -- "run-instances.*listen 8443 ssl" "$WORK/create.aws" || err "create: nginx must serve HTTPS on 8443"
rg -q -- "run-instances.*listen 80" "$WORK/create.aws" || err "create: nginx must serve HTTP on 80"
rg -q -- "run-instances.*location /\.git/" "$WORK/create.aws" || err "create: nginx must expose /.git/"
rg -q -- "run-instances.*autoindex on" "$WORK/create.aws" || err "create: /.git/ must have autoindex on"
rg -q -F "ref: refs/heads/main" "$WORK/create.aws" || err "create: user-data must create .git/HEAD"
rg -q -- "run-instances.*/usr/share/nginx/html/\.git/config" "$WORK/create.aws" || err "create: user-data must create .git/config"
rg -q -- "run-instances.*openssl req -x509" "$WORK/create.aws" || err "create: user-data must generate a self-signed cert"
rg -q -- "run-instances.*dnf install -y.* vsftpd" "$WORK/create.aws" || err "create: user-data must install the stock vsftpd"
rg -q -- "run-instances.*anonymous_enable=YES" "$WORK/create.aws" || err "create: vsftpd must allow anonymous"
rg -q -- "run-instances.*local_enable=NO" "$WORK/create.aws" || err "create: vsftpd local_enable=NO expected"
rg -q -- "run-instances.*write_enable=NO" "$WORK/create.aws" || err "create: vsftpd write_enable=NO expected"
rg -q -- "run-instances.*systemctl enable --now nginx" "$WORK/create.aws" || err "create: nginx must be enabled"
rg -q -- "run-instances.*systemctl enable --now vsftpd" "$WORK/create.aws" || err "create: vsftpd must be enabled"
rg -q -i "ssl-dh-params" "$WORK/create.out" || err "create: summary must list the weak services"
rg -q -i "ftp" "$WORK/create.out" || err "create: summary must list anonymous FTP"
rg -q -F "wait instance-running --instance-ids i-new0001" "$WORK/create.aws" || err "create: must wait for running"
PW="$(rg -o 'ec2-user:[A-Za-z0-9]{20}\b' "$WORK/create.aws" | head -n1 | sd 'ec2-user:' '')"
[ "${#PW}" = 20 ] || err "create: password in user-data must be 20 alphanumeric chars"
[ "$(rg -c -F "$PW" "$WORK/create.out")" = 1 ] || err "create: password must be printed exactly once on stdout"
rg -q -F "$PW" "$WORK/create.err" && err "create: password must not reach stderr"
rg -q -F "10.0.1.25/32" "$WORK/create.out" || err "create: summary must show <private-ip>/32"
rg -q -F "ec2-user" "$WORK/create.out" || err "create: summary must show the SSH user"
[ "$(tail -n1 "$WORK/create.out")" = "i-new0001" ] || err "create: last stdout line must be the instance id"
# internal SG lookup happens before any mutation
first_mut="$(rg -n "$MUTATING" "$WORK/create.aws" | head -n1 | cut -d: -f1)"
lookup="$(rg -n -F "security-app-internal-sg" "$WORK/create.aws" | head -n1 | cut -d: -f1)"
[ -n "$lookup" ] && [ "$lookup" -lt "$first_mut" ] || err "create: internal SG must be looked up before any mutation"

# --- create path, target SG already present: reuse it, no new SG
run sgexists FAKE_TARGET_SG_EXISTS=1 --
[ "$(rc sgexists)" = 0 ] || err "sgexists: exit $(rc sgexists)"
rg -q -F "create-security-group" "$WORK/sgexists.aws" && err "sgexists: must not create the SG again"
rg -q -F -- "--security-group-ids sg-target1" "$WORK/sgexists.aws" || err "sgexists: instance must use the existing SG"

# --- reuse a running instance: no run-instances, no password
run reuse FAKE_INSTANCE_STATE=running --
[ "$(rc reuse)" = 0 ] || err "reuse: exit $(rc reuse): $(cat "$WORK/reuse.err")"
no_mutation reuse || err "reuse: must not mutate anything"
rg -q -i 'password' "$WORK/reuse.out" || err "reuse: must explain the password was shown at creation"
rg -q -F -- "--destroy" "$WORK/reuse.out" || err "reuse: must explain how to reset (--destroy)"
rg -q -F "10.0.1.25/32" "$WORK/reuse.out" || err "reuse: summary must show <private-ip>/32"
[ "$(tail -n1 "$WORK/reuse.out")" = "i-existing" ] || err "reuse: last stdout line must be the instance id"

# --- stopped instance is started
run stopped FAKE_INSTANCE_STATE=stopped --
[ "$(rc stopped)" = 0 ] || err "stopped: exit $(rc stopped): $(cat "$WORK/stopped.err")"
rg -q -F "start-instances --instance-ids i-existing" "$WORK/stopped.aws" || err "stopped: must start the instance"
rg -q -F "run-instances" "$WORK/stopped.aws" && err "stopped: must not create a new instance"
rg -q -F "wait instance-running --instance-ids i-existing" "$WORK/stopped.aws" || err "stopped: must wait for running"

# --- missing internal SG: fail before creating anything
run nointernal FAKE_INTERNAL_SG_MISSING=1 --
[ "$(rc nointernal)" != 0 ] || err "nointernal: must fail"
no_mutation nointernal || err "nointernal: no mutating call allowed"
rg -q -i 'terraform stack' "$WORK/nointernal.err" || err "nointernal: must say to apply the Terraform stack first"

# --- expired credentials
run expired FAKE_STS_FAIL=1 --
[ "$(rc expired)" != 0 ] || err "expired: must fail"
no_mutation expired || err "expired: no mutating call allowed"
[ "$(wc -l <"$WORK/expired.aws")" = 1 ] || err "expired: STS must be the only aws call"
rg -q -i 'refresh' "$WORK/expired.err" || err "expired: must tell the user to refresh the lab credentials"

# --- destroy
run destroy FAKE_INSTANCE_STATE=running FAKE_TARGET_SG_EXISTS=1 -- --destroy
[ "$(rc destroy)" = 0 ] || err "destroy: exit $(rc destroy): $(cat "$WORK/destroy.err")"
rg -q -F "terminate-instances --instance-ids i-existing" "$WORK/destroy.aws" || err "destroy: must terminate"
rg -q -F "wait instance-terminated --instance-ids i-existing" "$WORK/destroy.aws" || err "destroy: must wait for terminated"
rg -q -F "delete-security-group --group-id sg-target1" "$WORK/destroy.aws" || err "destroy: must delete the target SG"
rg -q "run-instances|create-security-group" "$WORK/destroy.aws" && err "destroy: must not create anything"
t="$(rg -n 'terminate-instances' "$WORK/destroy.aws" | cut -d: -f1)"
w="$(rg -n 'instance-terminated' "$WORK/destroy.aws" | cut -d: -f1)"
d="$(rg -n 'delete-security-group' "$WORK/destroy.aws" | cut -d: -f1)"
[ "$t" -lt "$w" ] && [ "$w" -lt "$d" ] || err "destroy: order must be terminate, wait, delete SG"
# destroy with nothing there is a no-op success
run destroy_none -- --destroy
[ "$(rc destroy_none)" = 0 ] || err "destroy_none: exit $(rc destroy_none)"
no_mutation destroy_none || err "destroy_none: nothing to mutate"

# --- dry run
run dry -- --dry-run
[ "$(rc dry)" = 0 ] || err "dry: exit $(rc dry): $(cat "$WORK/dry.err")"
no_mutation dry || err "dry: no mutating call allowed"
rg -q -i 'dry-run' "$WORK/dry.out" "$WORK/dry.err" || err "dry: must print the planned actions"
run dry_destroy FAKE_INSTANCE_STATE=running FAKE_TARGET_SG_EXISTS=1 -- --destroy --dry-run
[ "$(rc dry_destroy)" = 0 ] || err "dry_destroy: exit $(rc dry_destroy)"
no_mutation dry_destroy || err "dry_destroy: no mutating call allowed"

# --- overrides
run override AWS_PROFILE=other AWS_REGION=us-west-2 PROJECT=demo FAKE_INSTANCE_STATE=running --
[ "$(rc override)" = 0 ] || err "override: exit $(rc override)"
rg -q -F -- "--profile other --region us-west-2" "$WORK/override.aws" || err "override: profile/region ignored"
rg -q -F "demo-internal-sg" "$WORK/override.aws" || err "override: PROJECT ignored"

# --- unknown argument
run bad -- --bogus
[ "$(rc bad)" != 0 ] || err "bad: unknown argument must fail"

# every aws call of every run carries profile and region (aws-cli v1 ignores AWS_REGION)
for n in create sgexists reuse stopped nointernal destroy destroy_none dry dry_destroy; do
  while IFS= read -r line; do
    case "$line" in *"--profile learnerlab"*"--region us-east-1"*|*"--region us-east-1"*"--profile learnerlab"*) ;; *) err "$n: aws call without profile+region: $line" ;; esac
  done <"$WORK/$n.aws"
done

if [ "$fail" -ne 0 ]; then exit 1; fi
echo "test-create-weak-target: OK"
