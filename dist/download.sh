#!/bin/bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# Blockchain Snapshots on AWS — Download & Extract
#
# Downloads a blockchain snapshot from S3 Standard and extracts it locally.
# Requires: EC2 instance in a supported region + VPC endpoint for S3.
#
# Performance (io2 Block Express, m8azn.12xlarge):
#   mountpoint-s3:           ~1,400 MB/s extracted (~1.3 min for 84 GB)
#   multi-process parallel:  ~1,200 MB/s extracted (~1.5 min for 84 GB)
#   aws-cli single-stream:    ~280 MB/s extracted (~6.5 min for 84 GB)
# ─────────────────────────────────────────────────────────────────────────────

# Bucket naming (docs/bucket-naming-and-environments.md):
#   production -> public-blockchain-snapshots-<region>
#   non-prod   -> public-blockchain-snapshots-<region>-<stage>
# STAGE selects the environment; empty/production = unsuffixed (the public tier).
STAGE="${STAGE:-}"
_SUFFIX=""; [ -n "$STAGE" ] && [ "$STAGE" != "production" ] && _SUFFIX="-$STAGE"
BUCKET_PREFIX="public-blockchain-snapshots"
SUPPORTED_REGIONS="us-east-1 us-west-2 eu-west-1 eu-central-1 ap-northeast-1 ap-southeast-1"

# Snapshot ID (<blockchain>-<network>-<client>) → "blockchain network client".
# Keys are namespaced by blockchain: <blockchain>/<network>/<client>/<block>/...
resolve_snapshot_id() {
    local id="$1"
    case "$id" in
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
        solana-mainnet-agave)        echo "solana mainnet agave" ;;
        *) echo "" ;;
    esac
}

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS] <snapshot> <output_dir>
       $(basename "$0") [OPTIONS] <network> <client> <output_dir>

Download and extract a blockchain snapshot to the current instance.

Snapshot can be specified as:
  A snapshot ID:   ethereum-mainnet-geth
  Or separately:   mainnet geth

Arguments:
  snapshot      Snapshot ID (e.g., ethereum-mainnet-geth)
  output_dir    Target directory (created if missing)

Options:
  --region REGION   Override auto-detected region
  --block NUMBER    Download a specific block instead of latest
  --json            Output result as JSON (for automation)
  -h, --help        Show this help

Examples:
  $(basename "$0") ethereum-mainnet-geth /var/lib/geth
  $(basename "$0") mainnet geth /var/lib/geth
  $(basename "$0") --block 25200000 ethereum-mainnet-geth /data/geth

Quick start (from curl):
  curl -sf https://raw.githubusercontent.com/<repo>/main/dist/download.sh | bash -s -- ethereum-mainnet-geth /var/lib/geth

Available snapshots:
  solana-mainnet-agave   (archives only — the Solana client unpacks at boot;
                          serves Agave/Jito/Firedancer/Sig alike)

Regions: us-east-1, us-west-2, eu-west-1, eu-central-1, ap-northeast-1, ap-southeast-1

Prerequisites:
  - EC2 instance in a supported region
  - VPC endpoint for S3 (Gateway type)
  - IAM: s3:GetObject, s3:HeadObject, s3:ListBucket
  - Installed: aws-cli v2, zstd, tar
  - Recommended: mountpoint-s3 (5x faster than single-stream)

Download methods (auto-selected, fastest first):
  1. mountpoint-s3    ~1,400 MB/s  FUSE-based, highest throughput
  2. parallel ranges  ~1,200 MB/s  Multi-process byte-range (>=8 vCPU)
  3. aws-cli CRT       ~280 MB/s  Single-stream fallback
EOF
    exit "${1:-0}"
}

die() {
    echo "ERROR: $1" >&2
    [[ -n "${2:-}" ]] && echo "" >&2 && echo "Fix: $2" >&2
    exit 1
}
info() { [[ "${JSON_OUTPUT:-false}" == "true" ]] || echo ":: $1"; }

# ─── Parse arguments ─────────────────────────────────────────────────────────

REGION_OVERRIDE=""
BLOCK_OVERRIDE=""
JSON_OUTPUT=false

POSITIONAL=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --region) REGION_OVERRIDE="$2"; shift 2 ;;
        --block) BLOCK_OVERRIDE="$2"; shift 2 ;;
        --json) JSON_OUTPUT=true; shift ;;
        -h|--help) usage 0 ;;
        -*) die "Unknown option: $1" "Use --help to see available options." ;;
        *) POSITIONAL+=("$1"); shift ;;
    esac
done

[[ ${#POSITIONAL[@]} -lt 2 ]] && usage 1

# Resolve: either "snapshot_id output_dir" or "network client output_dir"
if [[ ${#POSITIONAL[@]} -eq 2 ]]; then
    RESOLVED=$(resolve_snapshot_id "${POSITIONAL[0]}")
    if [[ -z "$RESOLVED" ]]; then
        die "Invalid snapshot ID: ${POSITIONAL[0]}" \
            "Use a valid ID like 'ethereum-mainnet-geth'. Run with --help to see all options."
    fi
    BLOCKCHAIN=$(echo "$RESOLVED" | cut -d' ' -f1)
    NETWORK=$(echo "$RESOLVED" | cut -d' ' -f2)
    CLIENT=$(echo "$RESOLVED" | cut -d' ' -f3)
    OUTPUT_DIR="${POSITIONAL[1]}"
elif [[ ${#POSITIONAL[@]} -ge 3 ]]; then
    # bare form: [blockchain] network client output_dir; blockchain defaults to ethereum
    if [[ ${#POSITIONAL[@]} -ge 4 ]]; then
        BLOCKCHAIN="${POSITIONAL[0]}"; NETWORK="${POSITIONAL[1]}"
        CLIENT="${POSITIONAL[2]}"; OUTPUT_DIR="${POSITIONAL[3]}"
    else
        BLOCKCHAIN="${BLOCKCHAIN:-ethereum}"
        NETWORK="${POSITIONAL[0]}"; CLIENT="${POSITIONAL[1]}"; OUTPUT_DIR="${POSITIONAL[2]}"
    fi
else
    usage 1
fi

case "$NETWORK" in
    mainnet|hoodi) ;;
    *) die "Invalid network '$NETWORK'." "Choose: mainnet, hoodi" ;;
esac
case "$BLOCKCHAIN:$CLIENT" in
    ethereum:geth|ethereum:besu|ethereum:nethermind|ethereum:erigon|ethereum:reth|solana:agave) ;;
    *) die "Invalid blockchain/client combination '$BLOCKCHAIN/$CLIENT'." \
        "Use an Ethereum client (geth, besu, nethermind, erigon, reth) or solana-mainnet-agave." ;;
esac

# ─── Preflight checks (fail fast) ────────────────────────────────────────────

# 1. Dependencies
for cmd in aws zstd tar curl; do
    if ! command -v "$cmd" &>/dev/null; then
        case "$cmd" in
            aws)  die "'aws' CLI not found." "Install: curl 'https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip' -o awscliv2.zip && unzip awscliv2.zip && sudo ./aws/install" ;;
            zstd) die "'zstd' not found." "Install: sudo dnf install -y zstd  # or: sudo apt-get install -y zstd" ;;
            tar)  die "'tar' not found." "Install: sudo dnf install -y tar" ;;
            curl) die "'curl' not found." "Install: sudo dnf install -y curl" ;;
        esac
    fi
done

# 2. AWS CLI version
if ! aws --version 2>&1 | grep -q "aws-cli/2"; then
    die "aws-cli v2 is required (found v1 or unknown)." \
        "Upgrade: curl 'https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip' -o awscliv2.zip && unzip awscliv2.zip && sudo ./aws/install --update"
fi

# 3. Check we're on EC2
if [[ -z "$REGION_OVERRIDE" ]]; then
    IMDS_TOKEN=$(curl -sf --max-time 2 -X PUT "http://169.254.169.254/latest/api/token" \
        -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null) \
        || die "Not running on EC2 (cannot reach instance metadata)." \
            "This script must run on an EC2 instance. Use --region to override detection."
    REGION=$(curl -sf -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" \
        http://169.254.169.254/latest/meta-data/placement/region)
else
    REGION="$REGION_OVERRIDE"
fi

# 4. Supported region
case "$REGION" in
    us-east-1|us-west-2|eu-west-1|eu-central-1|ap-northeast-1|ap-southeast-1) ;;
    *) die "Region '$REGION' is not supported." \
        "Launch your instance in one of: us-east-1, us-west-2, eu-west-1, eu-central-1, ap-northeast-1, ap-southeast-1" ;;
esac

BUCKET="${BUCKET_PREFIX}-${REGION}${_SUFFIX}"

# 5. IAM credentials exist
if ! aws sts get-caller-identity --region "$REGION" >/dev/null 2>&1; then
    die "No valid AWS credentials found." \
        "Attach an IAM role to this instance:
  aws ec2 associate-iam-instance-profile --instance-id \$(curl -s http://169.254.169.254/latest/meta-data/instance-id) \\
    --iam-instance-profile Name=<your-profile>"
fi

# 6. S3 VPC endpoint + bucket permissions
HEAD_RESULT=$(aws s3api head-bucket --bucket "$BUCKET" --region "$REGION" 2>&1 || true)
if echo "$HEAD_RESULT" | grep -qi "403\|AccessDenied\|Forbidden"; then
    CALLER=$(aws sts get-caller-identity --query 'Arn' --output text 2>/dev/null || echo "unknown")
    die "Access denied to bucket '$BUCKET' (identity: $CALLER)." \
        "Add this IAM policy to your role:
  {
    \"Effect\": \"Allow\",
    \"Action\": [\"s3:GetObject\", \"s3:HeadObject\", \"s3:HeadBucket\", \"s3:ListBucket\"],
    \"Resource\": [\"arn:aws:s3:::${BUCKET}\", \"arn:aws:s3:::${BUCKET}/*\"]
  }"
elif echo "$HEAD_RESULT" | grep -qi "Could not connect\|timed out\|Network"; then
    VPC_ID=$(curl -sf -H "X-aws-ec2-metadata-token: ${IMDS_TOKEN:-}" \
        http://169.254.169.254/latest/meta-data/network/interfaces/macs/$(curl -sf -H "X-aws-ec2-metadata-token: ${IMDS_TOKEN:-}" http://169.254.169.254/latest/meta-data/network/interfaces/macs/ | head -1)vpc-id 2>/dev/null || echo "<your-vpc-id>")
    RTB=$(aws ec2 describe-route-tables --region "$REGION" --filters "Name=vpc-id,Values=$VPC_ID" \
        --query 'RouteTables[0].RouteTableId' --output text 2>/dev/null || echo "<your-route-table-id>")
    die "Cannot reach S3 — no VPC endpoint detected." \
        "Create a Gateway VPC endpoint for S3:
  aws ec2 create-vpc-endpoint \\
    --vpc-id $VPC_ID \\
    --service-name com.amazonaws.${REGION}.s3 \\
    --route-table-ids $RTB \\
    --region $REGION"
elif [[ -n "$HEAD_RESULT" ]] && ! echo "$HEAD_RESULT" | grep -qi "BucketRegion"; then
    die "Unexpected error accessing bucket: $HEAD_RESULT"
fi

info "Preflight OK — Region: $REGION | Bucket: $BUCKET"

# ─── Resolve snapshot ────────────────────────────────────────────────────────

if [[ -n "$BLOCK_OVERRIDE" ]]; then
    BLOCK="$BLOCK_OVERRIDE"
else
    BLOCK=$(aws s3 cp "s3://$BUCKET/$BLOCKCHAIN/$NETWORK/$CLIENT/latest" - --region "$REGION" 2>/dev/null) \
        || die "No snapshot available for $BLOCKCHAIN/$NETWORK/$CLIENT." \
            "This snapshot may not be published yet. Check available snapshots:
  aws s3 ls s3://$BUCKET/ --region $REGION"
fi

S3_KEY="$BLOCKCHAIN/$NETWORK/$CLIENT/$BLOCK/snapshot.tar.zst"
SIZE_BYTES=$(aws s3api head-object --bucket "$BUCKET" --key "$S3_KEY" \
    --region "$REGION" --query 'ContentLength' --output text 2>/dev/null) \
    || die "Snapshot object not found: s3://$BUCKET/$S3_KEY" \
        "The block $BLOCK may have been rotated. Omit --block to get the latest."

SIZE_GB=$(python3 -c "print(f'{$SIZE_BYTES/1073741824:.1f}')" 2>/dev/null || echo "?")

# 7. Check disk space
AVAIL_KB=$(df --output=avail "$OUTPUT_DIR" 2>/dev/null | tail -1 || echo "0")
AVAIL_KB=${AVAIL_KB// /}
NEEDED_KB=$(( SIZE_BYTES * 2 / 1024 ))  # ~2x compressed for extracted
if [[ "$AVAIL_KB" -gt 0 && "$AVAIL_KB" -lt "$NEEDED_KB" ]]; then
    AVAIL_GB=$(( AVAIL_KB / 1048576 ))
    NEEDED_GB=$(( NEEDED_KB / 1048576 ))
    die "Insufficient disk space: ${AVAIL_GB} GB available, ~${NEEDED_GB} GB needed." \
        "Resize your EBS volume or mount a larger filesystem at $OUTPUT_DIR"
fi

info "Snapshot: $NETWORK/$CLIENT block $BLOCK (${SIZE_GB} GB compressed)"

# ─── Solana: download archives, do NOT extract ───────────────────────────────
# The Solana client consumes the ARCHIVE itself (unpacks at boot), and it parses
# slot+hash from the filename — so we download the full (+ incremental, if
# published) and restore the canonical names from the solana-meta.json sidecar.
# Start the validator with the archives in its snapshots dir + --no-snapshot-fetch.
if [[ "$BLOCKCHAIN" == "solana" ]]; then
    mkdir -p "$OUTPUT_DIR" || die "Cannot create directory: $OUTPUT_DIR"
    START_TIME=$(date +%s)
    DIR_KEY="$BLOCKCHAIN/$NETWORK/$CLIENT/$BLOCK"
    META=$(aws s3 cp "s3://$BUCKET/$DIR_KEY/solana-meta.json" - --region "$REGION" 2>/dev/null) \
        || die "Missing solana-meta.json sidecar for $DIR_KEY" \
            "The snapshot may still be publishing. Retry shortly."
    FULL_NAME=$(printf '%s' "$META" | python3 -c 'import json,sys; print(json.load(sys.stdin)["full"]["filename"])')
    INC_NAME=$(printf '%s' "$META" | python3 -c 'import json,sys; i=json.load(sys.stdin).get("incremental"); print(i["filename"] if i else "")')

    info "Downloading full snapshot → $OUTPUT_DIR/$FULL_NAME"
    aws s3 cp "s3://$BUCKET/$S3_KEY" "$OUTPUT_DIR/$FULL_NAME" --region "$REGION" --only-show-errors \
        || die "Full snapshot download failed"
    if [[ -n "$INC_NAME" ]]; then
        info "Downloading incremental snapshot → $OUTPUT_DIR/$INC_NAME"
        aws s3 cp "s3://$BUCKET/$DIR_KEY/incremental-snapshot.tar.zst" "$OUTPUT_DIR/$INC_NAME" \
            --region "$REGION" --only-show-errors \
            || info "WARN: incremental download failed — validator will boot from the full alone"
    fi
    if [[ ! -f "$OUTPUT_DIR/genesis.tar.bz2" ]]; then
        aws s3 cp "s3://$BUCKET/$BLOCKCHAIN/$NETWORK/$CLIENT/genesis.tar.bz2" \
            "$OUTPUT_DIR/genesis.tar.bz2" --region "$REGION" --only-show-errors 2>/dev/null \
            || info "NOTE: genesis.tar.bz2 not mirrored yet; the validator can fetch it from an entrypoint"
    fi

    END_TIME=$(date +%s); DURATION=$((END_TIME - START_TIME))
    if [[ "$JSON_OUTPUT" == "true" ]]; then
        cat <<JSONEOF
{"status":"success","blockchain":"solana","network":"$NETWORK","client":"$CLIENT","block":"$BLOCK","size_bytes":$SIZE_BYTES,"duration_seconds":$DURATION,"output_dir":"$OUTPUT_DIR","region":"$REGION","method":"archive","full_filename":"$FULL_NAME","incremental_filename":"$INC_NAME"}
JSONEOF
    else
        info "Complete: ${DURATION}s — archives in $OUTPUT_DIR (NOT extracted; the validator unpacks at boot)"
        info "Next: agave-validator --snapshots $OUTPUT_DIR --no-snapshot-fetch ..."
    fi
    exit 0
fi

# ─── Download + Extract ──────────────────────────────────────────────────────

mkdir -p "$OUTPUT_DIR" || die "Cannot create directory: $OUTPUT_DIR" \
    "Check permissions: sudo mkdir -p $OUTPUT_DIR && sudo chown \$(whoami) $OUTPUT_DIR"

HAS_MOUNTPOINT=false
command -v mount-s3 &>/dev/null && HAS_MOUNTPOINT=true

NPROCS=$(nproc 2>/dev/null || echo 4)
METHOD="crt"

info "Extracting to: $OUTPUT_DIR"
START_TIME=$(date +%s)

if [[ "$HAS_MOUNTPOINT" == "true" ]]; then
    METHOD="mountpoint"
    info "Method: mountpoint-s3 (highest throughput)"
    MP=$(mktemp -d)
    trap "fusermount -u '$MP' 2>/dev/null || umount '$MP' 2>/dev/null || true; rmdir '$MP' 2>/dev/null || true" EXIT

    mount-s3 "$BUCKET" "$MP" --region "$REGION" --read-only \
        --read-part-size 8388608 --maximum-throughput-gbps 200 2>/dev/null \
        || die "mountpoint-s3 mount failed." \
            "Check: FUSE available (modprobe fuse), and IAM allows s3:GetObject."

    [[ -f "$MP/$S3_KEY" ]] || die "File not accessible via mountpoint." \
        "Try without mountpoint: remove mount-s3 from PATH and rerun."
    cat "$MP/$S3_KEY" | zstd -d --long=27 | tar xf - -C "$OUTPUT_DIR" --no-same-owner

    trap - EXIT
    fusermount -u "$MP" 2>/dev/null || umount "$MP" 2>/dev/null || true
    rmdir "$MP" 2>/dev/null || true

elif [[ "$NPROCS" -ge 8 ]] && [[ "$SIZE_BYTES" -gt 10737418240 ]]; then
    METHOD="parallel"
    PARALLEL_WORKERS=$(( NPROCS > 32 ? 32 : NPROCS ))
    info "Method: parallel byte-range download (${PARALLEL_WORKERS} workers)"

    CHUNK_SIZE=$(( SIZE_BYTES / PARALLEL_WORKERS ))
    PIPE_DIR=$(mktemp -d)
    trap "rm -rf '$PIPE_DIR'" EXIT

    for i in $(seq 0 $((PARALLEL_WORKERS - 1))); do
        mkfifo "$PIPE_DIR/pipe_$(printf '%04d' $i)"
    done

    (
        for i in $(seq 0 $((PARALLEL_WORKERS - 1))); do
            cat "$PIPE_DIR/pipe_$(printf '%04d' $i)"
        done
    ) | zstd -d --long=27 | tar xf - -C "$OUTPUT_DIR" --no-same-owner &
    TAR_PID=$!

    WORKER_PIDS=()
    for i in $(seq 0 $((PARALLEL_WORKERS - 1))); do
        RANGE_START=$((i * CHUNK_SIZE))
        if [[ $i -eq $((PARALLEL_WORKERS - 1)) ]]; then
            RANGE_END=$((SIZE_BYTES - 1))
        else
            RANGE_END=$(( (i + 1) * CHUNK_SIZE - 1 ))
        fi
        (
            aws s3api get-object --bucket "$BUCKET" --key "$S3_KEY" \
                --range "bytes=${RANGE_START}-${RANGE_END}" \
                --region "$REGION" --cli-read-timeout 0 --no-cli-pager \
                /dev/stdout 2>/dev/null > "$PIPE_DIR/pipe_$(printf '%04d' $i)"
        ) &
        WORKER_PIDS+=($!)
    done

    for pid in "${WORKER_PIDS[@]}"; do
        wait "$pid" || true
    done
    wait $TAR_PID || die "Extraction failed." \
        "Try with mountpoint-s3 for better reliability: sudo dnf install -y https://s3.amazonaws.com/mountpoint-s3-release/latest/x86_64/mount-s3.rpm"

    trap - EXIT
    rm -rf "$PIPE_DIR"

else
    info "Method: aws-cli CRT (install mountpoint-s3 for 5x speed)"
    aws configure set default.s3.max_concurrent_requests 64
    aws configure set default.s3.multipart_chunksize 64MB
    aws configure set default.s3.multipart_threshold 256MB
    export AWS_USE_CRT=true

    aws s3 cp "s3://$BUCKET/$S3_KEY" - --region "$REGION" --cli-read-timeout 0 | \
        zstd -d --long=27 | tar xf - -C "$OUTPUT_DIR" --no-same-owner
fi

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

if [[ "$JSON_OUTPUT" == "true" ]]; then
    cat <<JSONEOF
{"status":"success","network":"$NETWORK","client":"$CLIENT","block":"$BLOCK","size_bytes":$SIZE_BYTES,"duration_seconds":$DURATION,"output_dir":"$OUTPUT_DIR","region":"$REGION","method":"$METHOD"}
JSONEOF
else
    info "Complete: ${DURATION}s — $NETWORK/$CLIENT block $BLOCK → $OUTPUT_DIR"
fi
