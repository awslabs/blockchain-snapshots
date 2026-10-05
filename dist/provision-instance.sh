#!/bin/bash
# provision-instance.sh — launch an i-class instance with NVMe RAID-0 + the
# fast download/unpack toolkit, for testing the repackaged-snapshot pipeline.
#
# Account-agnostic: pass everything via flags/env. Run from a workstation with
# AWS creds that can launch EC2 + pass an SSM-capable instance profile.
#
# Usage:
#   ./provision-instance.sh --subnet subnet-xxx --sg sg-xxx [options]
# Options (env var | flag):
#   INSTANCE_TYPE   --type        default i8g.12xlarge (48 vCPU, 3x NVMe)
#   AMI_ID          --ami         default = latest AL2023 arm64 (looked up)
#   SUBNET_ID       --subnet      REQUIRED
#   SECURITY_GROUP  --sg          REQUIRED
#   IAM_PROFILE     --iam-profile default EC2-SSM-Role (must allow SSM)
#   REGION          --region      default us-east-1
#   KEY_NAME        --key         optional SSH key (SSM works without it)
#   NAME            --name        instance Name tag, default repackaged-snapshot-test
set -euo pipefail

INSTANCE_TYPE="${INSTANCE_TYPE:-i8g.12xlarge}"
AMI_ID="${AMI_ID:-}"
SUBNET_ID="${SUBNET_ID:-}"
SECURITY_GROUP="${SECURITY_GROUP:-}"
IAM_PROFILE="${IAM_PROFILE:-EC2-SSM-Role}"
REGION="${REGION:-us-east-1}"
KEY_NAME="${KEY_NAME:-}"
NAME="${NAME:-repackaged-snapshot-test}"

while [ $# -gt 0 ]; do
  case "$1" in
    --type) INSTANCE_TYPE="$2"; shift 2;;
    --ami) AMI_ID="$2"; shift 2;;
    --subnet) SUBNET_ID="$2"; shift 2;;
    --sg) SECURITY_GROUP="$2"; shift 2;;
    --iam-profile) IAM_PROFILE="$2"; shift 2;;
    --region) REGION="$2"; shift 2;;
    --key) KEY_NAME="$2"; shift 2;;
    --name) NAME="$2"; shift 2;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

[ -z "$SUBNET_ID" ] && { echo "ERROR: --subnet required" >&2; exit 2; }
[ -z "$SECURITY_GROUP" ] && { echo "ERROR: --sg required" >&2; exit 2; }

# Resolve a default AMI (latest Amazon Linux 2023, arch matched to instance).
if [ -z "$AMI_ID" ]; then
  case "$INSTANCE_TYPE" in
    i8g.*|*g.*|*gd.*|c8g*|m8g*|r8g*) ARCH=arm64;;
    *) ARCH=x86_64;;
  esac
  AMI_ID=$(aws ssm get-parameter --region "$REGION" \
    --name "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-$ARCH" \
    --query 'Parameter.Value' --output text)
  echo "resolved AMI ($ARCH): $AMI_ID"
fi

# user-data: install toolkit deps + mount-s3 ONLY (reliable, package-level).
# Storage RAID/mount is deliberately NOT here — fire-and-forget cloud-init makes
# disk failures invisible and races device enumeration. It's a separate
# observable step (setup-storage.sh) run after launch. Written to a temp file
# via a plain heredoc (a heredoc inside $(cat <<...) breaks bash 3.2 / macOS).
UD_FILE="$(mktemp -t provision-userdata.XXXXXX)"
trap 'rm -f "$UD_FILE"' EXIT
cat > "$UD_FILE" <<'UD'
#!/bin/bash
exec > /var/log/provision.log 2>&1
export PATH=/usr/sbin:/usr/local/bin:/usr/bin:/bin:$PATH
dnf install -y mdadm xfsprogs python3-pip zstd >/dev/null 2>&1
python3 -c "import zstandard" 2>/dev/null || pip3 install -q 'zstandard~=0.25.0'
ARCH=$(uname -m)
case "$ARCH" in aarch64) MS=arm64;; *) MS=x86_64;; esac
command -v mount-s3 >/dev/null || {
  curl -sL "https://s3.amazonaws.com/mountpoint-s3-release/latest/$MS/mount-s3.rpm" -o /tmp/m.rpm
  dnf install -y /tmp/m.rpm >/dev/null 2>&1; }
aws configure set default.s3.preferred_transfer_client crt 2>/dev/null
aws configure set default.s3.target_bandwidth 100Gb/s 2>/dev/null
touch /var/log/provision-deps-done
UD

RUN_ARGS=(
  --region "$REGION" --image-id "$AMI_ID" --instance-type "$INSTANCE_TYPE"
  --subnet-id "$SUBNET_ID" --security-group-ids "$SECURITY_GROUP"
  --iam-instance-profile "Name=$IAM_PROFILE"
  --metadata-options "HttpEndpoint=enabled,HttpTokens=required"
  --user-data "file://$UD_FILE"
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$NAME}]"
)
[ -n "$KEY_NAME" ] && RUN_ARGS+=(--key-name "$KEY_NAME")

IID=$(aws ec2 run-instances "${RUN_ARGS[@]}" --query 'Instances[0].InstanceId' --output text)
echo "launched: $IID ($INSTANCE_TYPE) in $REGION"
echo "waiting for running..."
aws ec2 wait instance-running --region "$REGION" --instance-ids "$IID"
echo "instance running ($IID)."
echo
echo "Next, ON the instance (via SSM or SSH), in order:"
echo "  1. sudo bash setup-storage.sh         # RAID-0 + mount /data (observable)"
echo "  2. bash download-and-unpack.sh --bucket <bucket> --region $REGION"
echo "(deps + mount-s3 install via user-data; marker /var/log/provision-deps-done)"
echo "INSTANCE_ID=$IID"
