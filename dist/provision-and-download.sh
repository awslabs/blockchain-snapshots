#!/bin/bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# Blockchain Snapshots on AWS — Provision, Download, Extract, Deliver
#
# One-liner that:
#   1. Launches a fast m8azn.12xlarge extraction instance
#   2. Attaches a high-IOPS io2 volume (sized for the snapshot)
#   3. Downloads + decompresses + extracts the snapshot to the volume
#   4. Terminates the extraction instance
#   5. Converts the volume to gp3 (cost-optimized for node operation)
#   6. Optionally attaches to a target instance
#
# The result is a ready-to-use EBS volume with the fully extracted snapshot.
#
# Cost: ~$3-5 total (m8azn runs for ~10-15 min, io2 billed per-second)
# ─────────────────────────────────────────────────────────────────────────────

# Bucket naming (docs/bucket-naming-and-environments.md): STAGE selects env
# (empty/production = unsuffixed). Keys: <blockchain>/<network>/<client>/<block>/.
STAGE="${STAGE:-}"
_SUFFIX=""; [ -n "$STAGE" ] && [ "$STAGE" != "production" ] && _SUFFIX="-$STAGE"
BUCKET_PREFIX="public-blockchain-snapshots"
SUPPORTED_REGIONS="us-east-1 us-west-2 eu-west-1 eu-central-1 ap-northeast-1 ap-southeast-1"
EXTRACTOR_INSTANCE_TYPE="m8azn.12xlarge"
EXTRACTOR_AMI_SSM="/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"

# ─── Interface ────────────────────────────────────────────────────────────────

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS] <network> <client>

Provision a fast instance, download a snapshot to a new EBS volume,
then terminate the instance and deliver the volume.

Arguments:
  network       mainnet | hoodi
  client        geth | besu | nethermind | erigon | reth

Options:
  --region REGION         AWS region (default: us-east-1)
  --az AZ                 Availability zone (default: first AZ in region)
  --subnet-id SUBNET      Subnet for extraction instance (auto-detected)
  --block NUMBER          Specific block number (default: latest)
  --volume-size GB        Override volume size (default: 2x compressed size)
  --gp3-iops IOPS         IOPS for final gp3 volume (default: 6000)
  --gp3-throughput MB/s   Throughput for final gp3 (default: 400)
  --attach-to INSTANCE    Attach final volume to this instance
  --attach-device DEV     Device name for attachment (default: /dev/sdf)
  --keep-extractor        Don't terminate the extraction instance
  --json                  Output result as JSON
  --dry-run               Show plan without executing
  -h, --help              Show this help

Examples:
  # Basic: creates a gp3 volume with mainnet/geth, prints volume ID
  $(basename "$0") mainnet geth

  # Attach to existing node instance after extraction
  $(basename "$0") mainnet geth --attach-to i-0abc123def456

  # Custom region and volume specs
  $(basename "$0") --region eu-west-1 --gp3-iops 10000 mainnet reth

  # Dry run (show what would happen)
  $(basename "$0") --dry-run mainnet geth

Prerequisites:
  - AWS CLI v2 with IAM permissions for EC2, EBS, S3, SSM
  - The target region must have a VPC with S3 Gateway endpoint
  - Permissions: ec2:RunInstances, ec2:CreateVolume, ec2:AttachVolume,
    ec2:ModifyVolume, ec2:TerminateInstances, ssm:SendCommand, iam:PassRole
EOF
    exit "${1:-0}"
}

die() { echo "ERROR: $1" >&2; exit 1; }
info() { [[ "${JSON_OUTPUT:-false}" == "true" ]] || echo ":: $1"; }
step() { [[ "${JSON_OUTPUT:-false}" == "true" ]] || echo ""; echo "── $1 ──"; }

# ─── Parse arguments ─────────────────────────────────────────────────────────

REGION="us-east-1"
AZ=""
SUBNET_ID=""
BLOCK_OVERRIDE=""
VOLUME_SIZE_OVERRIDE=""
GP3_IOPS=6000
GP3_THROUGHPUT=400
ATTACH_TO=""
ATTACH_DEVICE="/dev/sdf"
KEEP_EXTRACTOR=false
JSON_OUTPUT=false
DRY_RUN=false

POSITIONAL=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --region) REGION="$2"; shift 2 ;;
        --az) AZ="$2"; shift 2 ;;
        --subnet-id) SUBNET_ID="$2"; shift 2 ;;
        --block) BLOCK_OVERRIDE="$2"; shift 2 ;;
        --volume-size) VOLUME_SIZE_OVERRIDE="$2"; shift 2 ;;
        --gp3-iops) GP3_IOPS="$2"; shift 2 ;;
        --gp3-throughput) GP3_THROUGHPUT="$2"; shift 2 ;;
        --attach-to) ATTACH_TO="$2"; shift 2 ;;
        --attach-device) ATTACH_DEVICE="$2"; shift 2 ;;
        --keep-extractor) KEEP_EXTRACTOR=true; shift ;;
        --json) JSON_OUTPUT=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        -h|--help) usage 0 ;;
        -*) die "Unknown option: $1" ;;
        *) POSITIONAL+=("$1"); shift ;;
    esac
done

[[ ${#POSITIONAL[@]} -lt 1 ]] && { echo "Error: snapshot is required." >&2; usage 1; }

# Resolve: either "snapshot_id" or "network client"
# id is <blockchain>-<network>-<client>; emits "blockchain network client".
resolve_snapshot_id() {
    case "$1" in
        ethereum-mainnet-geth)       echo "ethereum mainnet geth" ;;
        ethereum-mainnet-besu)       echo "ethereum mainnet besu" ;;
        ethereum-mainnet-nethermind) echo "ethereum mainnet nethermind" ;;
        ethereum-mainnet-erigon)     echo "ethereum mainnet erigon" ;;
        ethereum-mainnet-reth)       echo "ethereum mainnet reth" ;;
        ethereum-hoodi-geth)         echo "ethereum hoodi geth" ;;
        ethereum-hoodi-besu)         echo "ethereum hoodi besu" ;;
        ethereum-hoodi-nethermind)   echo "ethereum hoodi nethermind" ;;
        ethereum-hoodi-erigon)       echo "ethereum hoodi erigon" ;;
        ethereum-hoodi-reth)         echo "ethereum hoodi reth" ;;
        *) echo "" ;;
    esac
}

if [[ ${#POSITIONAL[@]} -eq 1 ]]; then
    RESOLVED=$(resolve_snapshot_id "${POSITIONAL[0]}")
    [[ -z "$RESOLVED" ]] && die "Invalid snapshot ID: ${POSITIONAL[0]}. Use --help to see options."
    BLOCKCHAIN=$(echo "$RESOLVED" | cut -d' ' -f1)
    NETWORK=$(echo "$RESOLVED" | cut -d' ' -f2)
    CLIENT=$(echo "$RESOLVED" | cut -d' ' -f3)
elif [[ ${#POSITIONAL[@]} -ge 2 ]]; then
    BLOCKCHAIN="${BLOCKCHAIN:-ethereum}"
    NETWORK="${POSITIONAL[0]}"
    CLIENT="${POSITIONAL[1]}"
else
    usage 1
fi

case "$NETWORK" in mainnet|hoodi) ;; *) die "Invalid network: $NETWORK" ;; esac
case "$CLIENT" in geth|besu|nethermind|erigon|reth) ;; *) die "Invalid client: $CLIENT" ;; esac
case "$REGION" in us-east-1|us-west-2|eu-west-1|eu-central-1|ap-northeast-1|ap-southeast-1) ;; *) die "Unsupported region: $REGION" ;; esac

# ─── Resolve snapshot metadata ───────────────────────────────────────────────

BUCKET="${BUCKET_PREFIX}-${REGION}${_SUFFIX}"

info "Resolving snapshot: $BLOCKCHAIN/$NETWORK/$CLIENT in $REGION..."

if [[ -n "$BLOCK_OVERRIDE" ]]; then
    BLOCK="$BLOCK_OVERRIDE"
else
    BLOCK=$(aws s3 cp "s3://$BUCKET/$BLOCKCHAIN/$NETWORK/$CLIENT/latest" - --region "$REGION" 2>/dev/null) \
        || die "No snapshot found for $BLOCKCHAIN/$NETWORK/$CLIENT in $REGION."
fi

S3_KEY="$BLOCKCHAIN/$NETWORK/$CLIENT/$BLOCK/snapshot.tar.zst"
SIZE_BYTES=$(aws s3api head-object --bucket "$BUCKET" --key "$S3_KEY" \
    --region "$REGION" --query 'ContentLength' --output text 2>/dev/null) \
    || die "Snapshot not found: s3://$BUCKET/$S3_KEY"

COMPRESSED_GB=$(( SIZE_BYTES / 1073741824 ))

if [[ -n "$VOLUME_SIZE_OVERRIDE" ]]; then
    VOLUME_GB="$VOLUME_SIZE_OVERRIDE"
else
    # 2x compressed size as reasonable estimate for extracted data + headroom
    VOLUME_GB=$(( COMPRESSED_GB * 2 + 50 ))
fi

# io2 Block Express needs min 4 GiB, and we want high IOPS for fast writes
IO2_IOPS=$(( VOLUME_GB * 50 ))  # 50 IOPS/GB (io2 max is 1000/GB)
[[ $IO2_IOPS -gt 64000 ]] && IO2_IOPS=64000
[[ $IO2_IOPS -lt 100 ]] && IO2_IOPS=100

info "Snapshot: $NETWORK/$CLIENT block $BLOCK (${COMPRESSED_GB} GB compressed)"
info "Volume: ${VOLUME_GB} GB io2 (${IO2_IOPS} IOPS) → gp3 (${GP3_IOPS} IOPS, ${GP3_THROUGHPUT} MB/s)"

# ─── Resolve AZ and subnet ───────────────────────────────────────────────────

if [[ -z "$AZ" ]]; then
    if [[ -n "$ATTACH_TO" ]]; then
        AZ=$(aws ec2 describe-instances --instance-ids "$ATTACH_TO" --region "$REGION" \
            --query 'Reservations[0].Instances[0].Placement.AvailabilityZone' --output text 2>/dev/null) \
            || die "Cannot determine AZ of target instance $ATTACH_TO"
        info "Using target instance AZ: $AZ"
    else
        AZ=$(aws ec2 describe-availability-zones --region "$REGION" \
            --query 'AvailabilityZones[0].ZoneName' --output text 2>/dev/null) \
            || die "Cannot list AZs in $REGION"
    fi
fi

if [[ -z "$SUBNET_ID" ]]; then
    SUBNET_ID=$(aws ec2 describe-subnets --region "$REGION" \
        --filters "Name=availability-zone,Values=$AZ" "Name=default-for-az,Values=true" \
        --query 'Subnets[0].SubnetId' --output text 2>/dev/null)
    [[ "$SUBNET_ID" == "None" || -z "$SUBNET_ID" ]] && \
        SUBNET_ID=$(aws ec2 describe-subnets --region "$REGION" \
            --filters "Name=availability-zone,Values=$AZ" \
            --query 'Subnets[0].SubnetId' --output text 2>/dev/null)
    [[ "$SUBNET_ID" == "None" || -z "$SUBNET_ID" ]] && \
        die "No subnet found in $AZ. Use --subnet-id."
fi

info "AZ: $AZ | Subnet: $SUBNET_ID"

# ─── Dry run ─────────────────────────────────────────────────────────────────

if [[ "$DRY_RUN" == "true" ]]; then
    cat <<PLAN
Plan:
  1. Create io2 volume: ${VOLUME_GB} GB, ${IO2_IOPS} IOPS in $AZ
  2. Launch $EXTRACTOR_INSTANCE_TYPE in $AZ ($SUBNET_ID)
  3. Attach volume, format ext4, mount at /data
  4. Download s3://$BUCKET/$S3_KEY (${COMPRESSED_GB} GB)
  5. Extract to /data (~10-15 min)
  6. Unmount, detach volume
  7. Terminate extractor instance
  8. Modify volume: io2 → gp3 (${GP3_IOPS} IOPS, ${GP3_THROUGHPUT} MB/s)
$([ -n "$ATTACH_TO" ] && echo "  9. Attach volume to $ATTACH_TO as $ATTACH_DEVICE")

Estimated time: 12-18 minutes
Estimated cost: ~\$3-5 (instance + io2 volume seconds)
PLAN
    exit 0
fi

# ─── Resolve AMI ─────────────────────────────────────────────────────────────

step "Resolving AMI"
AMI=$(aws ssm get-parameters --names "$EXTRACTOR_AMI_SSM" --region "$REGION" \
    --query 'Parameters[0].Value' --output text 2>/dev/null)
[[ -z "$AMI" || "$AMI" == "None" ]] && die "Cannot resolve AL2023 x86_64 AMI."
info "AMI: $AMI"

# ─── Create EBS volume ───────────────────────────────────────────────────────

step "Creating io2 volume (${VOLUME_GB} GB, ${IO2_IOPS} IOPS)"
VOLUME_ID=$(aws ec2 create-volume --region "$REGION" \
    --availability-zone "$AZ" \
    --volume-type io2 \
    --size "$VOLUME_GB" \
    --iops "$IO2_IOPS" \
    --encrypted \
    --tag-specifications "ResourceType=volume,Tags=[{Key=Name,Value=snapshot-${NETWORK}-${CLIENT}-${BLOCK}},{Key=Purpose,Value=blockchain-snapshot},{Key=Network,Value=$NETWORK},{Key=Client,Value=$CLIENT},{Key=Block,Value=$BLOCK}]" \
    --query 'VolumeId' --output text) \
    || die "Failed to create volume."
info "Volume: $VOLUME_ID"

aws ec2 wait volume-available --volume-ids "$VOLUME_ID" --region "$REGION" \
    || die "Volume did not become available."

# ─── Launch extractor instance ───────────────────────────────────────────────

step "Launching $EXTRACTOR_INSTANCE_TYPE"

USERDATA=$(cat <<'BOOTSTRAP'
#!/bin/bash
dnf install -y -q zstd tar bc
rpm -q mount-s3 || dnf install -y -q https://s3.amazonaws.com/mountpoint-s3-release/latest/x86_64/mount-s3.rpm 2>/dev/null || true
echo "READY" > /tmp/.extractor-ready
BOOTSTRAP
)

INSTANCE_ID=$(aws ec2 run-instances --region "$REGION" \
    --image-id "$AMI" \
    --instance-type "$EXTRACTOR_INSTANCE_TYPE" \
    --subnet-id "$SUBNET_ID" \
    --iam-instance-profile Name=s3-express-benchmark-profile \
    --metadata-options "HttpEndpoint=enabled,HttpTokens=required" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=snapshot-extractor-${NETWORK}-${CLIENT}},{Key=Purpose,Value=snapshot-extraction}]" \
    --user-data "$USERDATA" \
    --instance-initiated-shutdown-behavior terminate \
    --count 1 \
    --query 'Instances[0].InstanceId' --output text) \
    || die "Failed to launch instance."
info "Instance: $INSTANCE_ID"

cleanup_on_failure() {
    echo "Cleaning up after failure..." >&2
    aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" --region "$REGION" 2>/dev/null || true
    # Don't delete volume on failure — user may want to inspect
    echo "Volume $VOLUME_ID preserved for inspection." >&2
}
trap cleanup_on_failure ERR

aws ec2 wait instance-running --instance-ids "$INSTANCE_ID" --region "$REGION"
info "Instance running."

# ─── Attach volume ───────────────────────────────────────────────────────────

step "Attaching volume"
aws ec2 attach-volume --region "$REGION" \
    --volume-id "$VOLUME_ID" \
    --instance-id "$INSTANCE_ID" \
    --device /dev/sdf >/dev/null \
    || die "Failed to attach volume."

aws ec2 wait volume-in-use --volume-ids "$VOLUME_ID" --region "$REGION"
info "Volume attached as /dev/sdf"

# ─── Wait for SSM + userdata ─────────────────────────────────────────────────

step "Waiting for instance bootstrap"
for i in $(seq 1 60); do
    STATUS=$(aws ssm describe-instance-information --region "$REGION" \
        --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
        --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null || echo "")
    [[ "$STATUS" == "Online" ]] && break
    sleep 5
done
[[ "$STATUS" != "Online" ]] && die "SSM agent did not come online within 5 minutes."

# Wait for userdata to finish
for i in $(seq 1 30); do
    READY=$(aws ssm send-command --instance-ids "$INSTANCE_ID" --region "$REGION" \
        --document-name "AWS-RunShellScript" \
        --parameters 'commands=["cat /tmp/.extractor-ready 2>/dev/null || echo NOTREADY"]' \
        --query 'Command.CommandId' --output text 2>/dev/null)
    sleep 3
    RESULT=$(aws ssm get-command-invocation --command-id "$READY" \
        --instance-id "$INSTANCE_ID" --region "$REGION" \
        --query 'StandardOutputContent' --output text 2>/dev/null || echo "")
    [[ "$RESULT" == *"READY"* ]] && break
    sleep 5
done
info "Instance bootstrapped."

# ─── Format volume + download + extract ──────────────────────────────────────

step "Formatting volume and extracting snapshot"

EXTRACT_CMD=$(cat <<EXTRACTEOF
#!/bin/bash
set -euo pipefail

# Format and mount
DEVICE=\$(lsblk -o NAME,SIZE -b | grep "$((VOLUME_GB * 1073741824 / 1000000000))" | head -1 | awk '{print "/dev/" \$1}')
[ -z "\$DEVICE" ] && DEVICE=/dev/nvme1n1
mkfs.ext4 -q -E nodiscard "\$DEVICE"
mkdir -p /data
mount "\$DEVICE" /data

# Configure S3 access
aws configure set default.s3.max_concurrent_requests 64
aws configure set default.s3.multipart_chunksize 64MB
aws configure set default.s3.multipart_threshold 256MB
export AWS_USE_CRT=true

BUCKET="$BUCKET"
S3_KEY="$S3_KEY"
REGION="$REGION"

echo "Downloading and extracting..."
START=\$(date +%s)

if command -v mount-s3 &>/dev/null; then
    mkdir -p /mnt/s3
    mount-s3 "\$BUCKET" /mnt/s3 --region "\$REGION" --read-only --read-part-size 8388608 --maximum-throughput-gbps 200 2>/dev/null
    cat "/mnt/s3/\$S3_KEY" | zstd -d | tar xf - -C /data --no-same-owner
    fusermount -u /mnt/s3 2>/dev/null || umount /mnt/s3 2>/dev/null || true
else
    aws s3 cp "s3://\$BUCKET/\$S3_KEY" - --region "\$REGION" --cli-read-timeout 0 | zstd -d | tar xf - -C /data --no-same-owner
fi

END=\$(date +%s)
DUR=\$((END - START))
SIZE=\$(du -sb /data | cut -f1)
echo "EXTRACTION_COMPLETE duration=\${DUR}s size=\${SIZE}"

# Unmount
sync
umount /data
EXTRACTEOF
)

CMD_ID=$(aws ssm send-command --instance-ids "$INSTANCE_ID" --region "$REGION" \
    --document-name "AWS-RunShellScript" \
    --timeout-seconds 3600 \
    --parameters "commands=[\"$EXTRACT_CMD\"]" \
    --query 'Command.CommandId' --output text) \
    || die "Failed to send extraction command."

info "Extraction running (command: $CMD_ID)..."

# Poll for completion
while true; do
    STATUS=$(aws ssm get-command-invocation --command-id "$CMD_ID" \
        --instance-id "$INSTANCE_ID" --region "$REGION" \
        --query 'Status' --output text 2>/dev/null || echo "Pending")
    case "$STATUS" in
        Success) break ;;
        Failed|TimedOut|Cancelled)
            OUTPUT=$(aws ssm get-command-invocation --command-id "$CMD_ID" \
                --instance-id "$INSTANCE_ID" --region "$REGION" \
                --query 'StandardErrorContent' --output text 2>/dev/null || echo "unknown")
            die "Extraction failed ($STATUS): $OUTPUT" ;;
    esac
    sleep 15
done

EXTRACT_OUTPUT=$(aws ssm get-command-invocation --command-id "$CMD_ID" \
    --instance-id "$INSTANCE_ID" --region "$REGION" \
    --query 'StandardOutputContent' --output text 2>/dev/null || echo "")
info "$EXTRACT_OUTPUT" | grep "EXTRACTION_COMPLETE" || true

# ─── Detach volume and terminate instance ────────────────────────────────────

step "Detaching volume and terminating extractor"

aws ec2 detach-volume --volume-id "$VOLUME_ID" --region "$REGION" >/dev/null 2>&1 || true
aws ec2 wait volume-available --volume-ids "$VOLUME_ID" --region "$REGION"

if [[ "$KEEP_EXTRACTOR" == "false" ]]; then
    aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" --region "$REGION" >/dev/null
    info "Terminated: $INSTANCE_ID"
else
    info "Kept extractor: $INSTANCE_ID (--keep-extractor)"
fi

trap - ERR

# ─── Convert volume to gp3 ──────────────────────────────────────────────────

step "Converting volume to gp3 (${GP3_IOPS} IOPS, ${GP3_THROUGHPUT} MB/s)"

aws ec2 modify-volume --region "$REGION" \
    --volume-id "$VOLUME_ID" \
    --volume-type gp3 \
    --iops "$GP3_IOPS" \
    --throughput "$GP3_THROUGHPUT" >/dev/null \
    || die "Failed to modify volume to gp3."

# Wait for modification to complete
for i in $(seq 1 60); do
    MOD_STATE=$(aws ec2 describe-volumes-modifications --region "$REGION" \
        --volume-ids "$VOLUME_ID" \
        --query 'VolumesModifications[0].ModificationState' --output text 2>/dev/null || echo "")
    [[ "$MOD_STATE" == "completed" || "$MOD_STATE" == "optimizing" ]] && break
    sleep 10
done
info "Volume converted to gp3."

# ─── Optionally attach to target ─────────────────────────────────────────────

if [[ -n "$ATTACH_TO" ]]; then
    step "Attaching to $ATTACH_TO as $ATTACH_DEVICE"
    aws ec2 attach-volume --region "$REGION" \
        --volume-id "$VOLUME_ID" \
        --instance-id "$ATTACH_TO" \
        --device "$ATTACH_DEVICE" >/dev/null \
        || die "Failed to attach volume to $ATTACH_TO."
    aws ec2 wait volume-in-use --volume-ids "$VOLUME_ID" --region "$REGION"
    info "Attached. Mount with: sudo mount $ATTACH_DEVICE /path/to/datadir"
fi

# ─── Output ──────────────────────────────────────────────────────────────────

if [[ "$JSON_OUTPUT" == "true" ]]; then
    cat <<JSONEOF
{"status":"success","volume_id":"$VOLUME_ID","region":"$REGION","az":"$AZ","network":"$NETWORK","client":"$CLIENT","block":"$BLOCK","volume_type":"gp3","volume_size_gb":$VOLUME_GB,"iops":$GP3_IOPS,"throughput_mbps":$GP3_THROUGHPUT$([ -n "$ATTACH_TO" ] && echo ",\"attached_to\":\"$ATTACH_TO\",\"device\":\"$ATTACH_DEVICE\"")}
JSONEOF
else
    echo ""
    echo "═══════════════════════════════════════════════════════"
    echo "  VOLUME READY"
    echo "═══════════════════════════════════════════════════════"
    echo "  Volume ID:    $VOLUME_ID"
    echo "  Region/AZ:    $REGION / $AZ"
    echo "  Type:         gp3 (${GP3_IOPS} IOPS, ${GP3_THROUGHPUT} MB/s)"
    echo "  Size:         ${VOLUME_GB} GB"
    echo "  Contents:     $NETWORK/$CLIENT block $BLOCK"
    if [[ -n "$ATTACH_TO" ]]; then
        echo "  Attached to:  $ATTACH_TO ($ATTACH_DEVICE)"
        echo ""
        echo "  Mount: sudo mount $ATTACH_DEVICE /var/lib/$CLIENT"
    else
        echo ""
        echo "  Attach: aws ec2 attach-volume --volume-id $VOLUME_ID \\"
        echo "    --instance-id <your-node> --device /dev/sdf --region $REGION"
        echo "  Mount:  sudo mount /dev/sdf /var/lib/$CLIENT"
    fi
    echo "═══════════════════════════════════════════════════════"
fi
