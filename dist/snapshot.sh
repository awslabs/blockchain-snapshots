#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
# snapshot.sh — one catalog-driven entrypoint for Blockchain Snapshots on AWS.
#
# The user selects a stable snapshot ID (or metadata selectors). This script
# resolves the latest artifact from the active Region's public catalog, adapts
# catalog v1 into a versioned delivery protocol, then dispatches to one of:
#   tar-zstd-seekable-v1  manifest-driven parallel extraction
#   tar-zstd-stream-v1    streaming zstd | tar extraction
#   archive-set-v1        retained full/incremental/genesis archives
#
# No snapshot IDs, bucket names, Regions, or delivery choices are hardcoded in
# this file. Data comes from the GitHub Pages region registry and regional
# catalog. snapshot-catalog.py contains the temporary catalog-v1 adapter.
#
# Source this file to inspect or run one step; main runs only when executed.

# ── Defaults and run state ───────────────────────────────────────────────────
REGISTRY_URL="${REGISTRY_URL:-https://awslabs.github.io/blockchain-snapshots/config/regions.json}"
REGISTRY_FALLBACK="${REGISTRY_FALLBACK:-}"
SNAPSHOT_ID="${SNAPSHOT_ID:-}"
CHAIN="${CHAIN:-}"
NETWORK="${NETWORK:-}"
CLIENT="${CLIENT:-}"
REGION="${REGION:-${AWS_REGION:-${AWS_DEFAULT_REGION:-}}}"
OUT="${OUT:-}"
SOURCE="${SOURCE:-auto}"
WORKERS="${WORKERS:-0}"
ODIRECT="${ODIRECT:-auto}"
MS3_GBPS="${MS3_GBPS:-25}"
DEBUG="${DEBUG:-0}"
DROP_CACHES="${DROP_CACHES:-0}"
FUSE_DEV="${FUSE_DEV:-/dev/fuse}"
INSTALL_DEPS=0
FORCE=0
JSON_OUTPUT=0
LIST_ONLY=0
SETUP_ONLY=0
LEGACY_PARALLEL=0
BUCKET="${BUCKET:-}"
PREFIX="${PREFIX:-}"
ARTIFACT="${ARTIFACT:-snapshot.tar.zst}"
MANIFEST="${MANIFEST:-download-manifest.json}"

RETRY_MAX_ATTEMPTS="${RETRY_MAX_ATTEMPTS:-6}"
RETRY_BASE_S=1
RETRY_CAP_S=20
S3_PERMANENT_ERRORS='403|Forbidden|AccessDenied|404|Not Found|NoSuchKey|NoSuchBucket|InvalidAccessKeyId|SignatureDoesNotMatch|ExpiredToken|InvalidClientTokenId|UnrecognizedClientException|AuthFailure|Unable to locate credentials'

HERE=""
WORKDIR=""
RESOLVED_FILE=""
READ_VIA=""
MNT_DIR=""
MOUNTED=0

PROTOCOL=""
VERSION_ID=""
SNAPSHOT_URI=""
SNAPSHOT_BUCKET=""
SNAPSHOT_KEY=""
SNAPSHOT_SIZE=""
MANIFEST_URI=""
MANIFEST_KEY=""
METADATA_URI=""
FULL_FILENAME=""
INCREMENTAL_URI=""
INCREMENTAL_FILENAME=""
GENESIS_URI=""
REQUIRED_BYTES=""
NORMALIZED_FROM=""
EXTRACT_CMD=()

usage(){
  cat <<'EOF'
Usage:
  snapshot.sh --setup
  snapshot.sh --snapshot ID [options]
  snapshot.sh --chain CHAIN [--network NETWORK] [--client CLIENT] [options]
  snapshot.sh --list [--region REGION] [--json]

Resolve the latest snapshot from the public catalog and download it. Delivery
method is data-driven; users do not choose remint/mirror/archive or a version.

Selection:
  --setup             install/verify tools only; do not resolve or download
  --snapshot ID       stable catalog ID, e.g. ethereum-mainnet-geth
  --chain CHAIN       convenience selector; must resolve to one entry
  --network NETWORK   narrow a convenience selection
  --client CLIENT     narrow a convenience selection
  --list              list available snapshots in this Region and exit

Options:
  --region REGION     active Region (default: AWS_REGION, then EC2 IMDS)
  --out DIR           output directory (default /data/<snapshot-id>)
  --source MODE       auto | mount | s3 (default auto)
  --workers N         parallel workers; 0 = container-aware auto
  --o-direct MODE     auto | on | off (default auto)
  --registry URL      active-region registry override
  --install-deps      install missing dependencies (apt/dnf/yum)
  --force             clear a non-empty output for filesystem delivery
  --json              machine-readable final result (logs stay on stderr)
  -h, --help          show this help

Environment:
  REGISTRY_URL, SOURCE, WORKERS, ODIRECT, MS3_GBPS, DEBUG=1, DROP_CACHES=1
EOF
}

# ── Logging ──────────────────────────────────────────────────────────────────
_emit(){ if [ "$JSON_OUTPUT" -eq 1 ]; then echo "$*" >&2; else echo "$*"; fi; }
say(){ _emit "[$(date -u +%H:%M:%S)] $*"; }
warn(){ echo "[$(date -u +%H:%M:%S)] WARN: $*" >&2; }
die(){ echo "ERROR: $*" >&2; exit 1; }
usage_error(){ echo "ERROR: $*" >&2; echo "Run with --help for usage." >&2; exit 2; }
human_size(){ awk -v b="$1" 'BEGIN { if (b >= 1073741824) printf "%.1f GiB", b/1073741824; else printf "%.0f MiB", b/1048576 }'; }
need_value(){ [ "$2" -ge 2 ] || usage_error "$1 needs a value"; }

# ── Arguments ────────────────────────────────────────────────────────────────
parse_args(){
  while [ $# -gt 0 ]; do
    case "$1" in
      --snapshot) need_value "$1" $#; SNAPSHOT_ID="$2"; shift 2;;
      --chain) need_value "$1" $#; CHAIN="$2"; shift 2;;
      --network) need_value "$1" $#; NETWORK="$2"; shift 2;;
      --client) need_value "$1" $#; CLIENT="$2"; shift 2;;
      --region) need_value "$1" $#; REGION="$2"; shift 2;;
      --out) need_value "$1" $#; OUT="$2"; shift 2;;
      --source) need_value "$1" $#; SOURCE="$2"; shift 2;;
      --workers) need_value "$1" $#; WORKERS="$2"; shift 2;;
      --o-direct) need_value "$1" $#; ODIRECT="$2"; shift 2;;
      --registry) need_value "$1" $#; REGISTRY_URL="$2"; shift 2;;
      --install-deps) INSTALL_DEPS=1; shift;;
      --force) FORCE=1; shift;;
      --json) JSON_OUTPUT=1; shift;;
      --list) LIST_ONLY=1; shift;;
      --setup) SETUP_ONLY=1; shift;;
      --legacy-parallel) LEGACY_PARALLEL=1; shift;;
      --bucket) need_value "$1" $#; BUCKET="$2"; shift 2;;
      --prefix) need_value "$1" $#; PREFIX="$2"; shift 2;;
      --artifact) need_value "$1" $#; ARTIFACT="$2"; shift 2;;
      --manifest) need_value "$1" $#; MANIFEST="$2"; shift 2;;
      -h|--help) usage; exit 0;;
      *) usage_error "unknown argument: $1";;
    esac
  done
  case "$SOURCE" in auto|mount|s3) ;; *) usage_error "--source must be auto, mount or s3 (got '$SOURCE')";; esac
  case "$ODIRECT" in auto|on|off) ;; *) usage_error "--o-direct must be auto, on or off (got '$ODIRECT')";; esac
  case "$WORKERS" in ''|*[!0-9]*) usage_error "--workers must be a whole number (got '$WORKERS')";; esac
  if [ "$SETUP_ONLY" -eq 1 ]; then
    if [ -n "$SNAPSHOT_ID$CHAIN$NETWORK$CLIENT$OUT" ] || [ "$LIST_ONLY" -eq 1 ] || [ "$LEGACY_PARALLEL" -eq 1 ]; then
      usage_error "--setup cannot be combined with snapshot selection, --list, --out, or legacy mode"
    fi
    INSTALL_DEPS=1
    return
  fi
  if [ "$LEGACY_PARALLEL" -eq 1 ]; then
    [ -n "$BUCKET" ] || usage_error "--bucket is required"
    [ -n "$PREFIX" ] || usage_error "--prefix is required"
    PREFIX="${PREFIX#/}"; PREFIX="${PREFIX%/}"
    [ -n "$REGION" ] || REGION=us-east-1
    [ -n "$OUT" ] || OUT=/data/extract
    return
  fi
  if [ -n "$SNAPSHOT_ID" ] && { [ -n "$CHAIN" ] || [ -n "$NETWORK" ] || [ -n "$CLIENT" ]; }; then
    usage_error "--snapshot cannot be combined with --chain/--network/--client"
  fi
  if [ "$LIST_ONLY" -eq 0 ] && [ -z "$SNAPSHOT_ID$CHAIN$NETWORK$CLIENT" ]; then
    LIST_ONLY=1
  fi
}

# ── Output safety (always before dependency/network work when --out is given) ─
abs_path(){
  local p="$1" parent base
  case "$p" in /*) ;; *) p="$PWD/$p";; esac
  while [ "${p%/}" != "$p" ]; do p="${p%/}"; done
  parent="${p%/*}"; base="${p##*/}"
  if [ -n "$parent" ] && [ -d "$parent" ]; then
    parent="$(cd "$parent" 2>/dev/null && pwd -P)" || parent="${p%/*}"
    [ "$parent" = / ] && parent=""
  fi
  printf '%s' "$parent${base:+/$base}"
}

is_mount_point(){
  if command -v mountpoint >/dev/null 2>&1; then mountpoint -q "$1" 2>/dev/null
  elif [ -r /proc/self/mountinfo ]; then
    awk -v p="$1" '$5 == p { found=1 } END { exit !found }' /proc/self/mountinfo
  else return 1; fi
}

refuse_if_system_root(){
  local home="${HOME:-}"
  case "$1" in
    ""|/data|/mnt|/home|/root|/var|/etc|/boot|/usr|/opt|/srv|/tmp|"${home%/}")
      echo "ERROR: refusing to use '${1:-/}' as the output dir (looks like a system/data root). Use a dedicated subdirectory, e.g. --out /data/ethereum-mainnet-geth." >&2
      exit 2;;
  esac
}

guard_output_path(){
  [ -n "$OUT" ] || return 0
  local raw="$OUT"
  while [ "${raw%/}" != "$raw" ]; do raw="${raw%/}"; done
  refuse_if_system_root "$raw"
  OUT="$(abs_path "$OUT")"
  refuse_if_system_root "$OUT"
  if is_mount_point "$OUT"; then
    echo "ERROR: --out '$OUT' is a mount point. Use a dedicated subdirectory under it." >&2
    exit 2
  fi
}

guard_output_contents(){
  # Filesystem handlers replace the output tree; archive-set adds named files.
  case "$PROTOCOL" in tar-zstd-seekable-v1|tar-zstd-stream-v1) ;;
    *) return 0;; esac
  if [ -d "$OUT" ] && [ -n "$(ls -A "$OUT" 2>/dev/null)" ] && [ "$FORCE" -ne 1 ]; then
    echo "ERROR: --out '$OUT' is not empty. Its contents would be deleted. Re-run with --force if intended." >&2
    exit 2
  fi
}

make_workdir(){ WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/snapshot-dl.XXXXXX")"; RESOLVED_FILE="$WORKDIR/resolved.json"; }

# ── Package installation ─────────────────────────────────────────────────────
as_root(){
  if [ "$(id -u)" -eq 0 ]; then "$@"
  elif command -v sudo >/dev/null 2>&1; then sudo "$@"
  else
    die "need root to run '$1' (not root, and sudo is absent). Re-run as root, or install dependencies yourself; in a container, bake them into the image."
  fi
}

detect_pkg_mgr(){
  if command -v apt-get >/dev/null; then echo apt
  elif command -v dnf >/dev/null; then echo dnf
  elif command -v yum >/dev/null; then echo yum
  else echo ""; fi
}

mount_s3_url(){
  local arch; case "$(uname -m)" in aarch64|arm64) arch=arm64;; *) arch=x86_64;; esac
  echo "https://s3.amazonaws.com/mountpoint-s3-release/latest/${arch}/mount-s3.$1"
}

awscli_bundle_url(){
  local arch; case "$(uname -m)" in aarch64|arm64) arch=aarch64;; *) arch=x86_64;; esac
  echo "https://awscli.amazonaws.com/awscli-exe-linux-${arch}.zip"
}

install_aws_cli(){
  command -v unzip >/dev/null 2>&1 || die "unzip is needed to install AWS CLI v2"
  say "installing AWS CLI v2 for $(uname -m)"
  curl -fsSL "$(awscli_bundle_url)" -o "$WORKDIR/awscliv2.zip"
  unzip -q "$WORKDIR/awscliv2.zip" -d "$WORKDIR/awscli"
  as_root "$WORKDIR/awscli/aws/install" --update >/dev/null 2>&1 || as_root "$WORKDIR/awscli/aws/install" >/dev/null
}

mount_deps_wanted(){
  case "$SOURCE" in mount) return 0;; s3) return 1;; *) [ -c "$FUSE_DEV" ];; esac
}

apt_install(){ as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@" >/dev/null; }

install_deps_apt(){
  local fuse="$1" pkgs="ca-certificates curl unzip python3 python3-boto3 zstd tar"
  [ "$fuse" -eq 1 ] && pkgs="$pkgs fuse3"
  as_root env DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null || warn "apt-get update failed; trying install"
  # shellcheck disable=SC2086
  # Intentional package word list.
  apt_install $pkgs
  if ! python3 -c 'import zstandard' 2>/dev/null; then
    apt_install python3-zstandard 2>/dev/null || { apt_install python3-pip; python3 -m pip install --quiet 'zstandard>=0.22'; }
  fi
  if [ "$fuse" -eq 1 ] && ! command -v mount-s3 >/dev/null 2>&1; then
    curl -fsSL "$(mount_s3_url deb)" -o "$WORKDIR/mount-s3.deb"
    apt_install "$WORKDIR/mount-s3.deb"
  fi
  aws --version 2>&1 | grep -q 'aws-cli/2' || install_aws_cli
}

install_deps_rpm(){
  local pm="$1" fuse="$2"
  as_root "$pm" install -y python3 python3-pip unzip zstd tar >/dev/null
  if [ "$fuse" -eq 1 ]; then as_root "$pm" install -y fuse3 >/dev/null 2>&1 || true; fi
  python3 -c 'import zstandard' 2>/dev/null || python3 -m pip install --quiet 'zstandard>=0.22'
  python3 -c 'import boto3' 2>/dev/null || as_root "$pm" install -y python3-boto3 >/dev/null 2>&1 || python3 -m pip install --quiet 'boto3>=1.20'
  aws --version 2>&1 | grep -q 'aws-cli/2' || install_aws_cli
  if [ "$fuse" -eq 1 ] && ! command -v mount-s3 >/dev/null 2>&1; then
    curl -fsSL "$(mount_s3_url rpm)" -o "$WORKDIR/mount-s3.rpm"
    as_root "$pm" install -y "$WORKDIR/mount-s3.rpm" >/dev/null
  fi
}

install_deps(){
  local pm fuse=0; pm="$(detect_pkg_mgr)"
  [ -n "$pm" ] || die "--install-deps: no supported package manager (apt/dnf/yum)"
  mount_deps_wanted && fuse=1
  say "installing dependencies via $pm (mount-s3 + FUSE: $([ "$fuse" -eq 1 ] && echo yes || echo skipped))"
  case "$pm" in apt) install_deps_apt "$fuse";; *) install_deps_rpm "$pm" "$fuse";; esac
}

# ── Base preflight and Region ────────────────────────────────────────────────
preflight_resolver(){
  command -v python3 >/dev/null 2>&1 || die "python3 missing (or use --install-deps)"
}

preflight_aws(){
  command -v aws >/dev/null 2>&1 || die "AWS CLI missing (run snapshot.sh --setup)"
  aws --version 2>&1 | grep -q 'aws-cli/2' || die "AWS CLI v2 is required (run snapshot.sh --setup)"
}

preflight_setup(){
  preflight_resolver
  preflight_aws
  local missing=0
  for command in curl unzip zstd tar; do
    command -v "$command" >/dev/null 2>&1 || { echo "ERROR: setup did not install $command" >&2; missing=1; }
  done
  python3 -c 'import boto3,zstandard' 2>/dev/null || { echo "ERROR: setup did not install Python boto3 and zstandard" >&2; missing=1; }
  [ "$missing" -eq 0 ] || exit 1
  say "setup complete: AWS CLI v2, Python 3, boto3, zstandard, zstd, tar, curl and unzip"
  if command -v mount-s3 >/dev/null 2>&1; then
    say "optional mountpoint-s3 installed"
  else
    say "optional mountpoint-s3 skipped; direct S3 delivery is available"
  fi
}

detect_imds_region(){
  command -v curl >/dev/null 2>&1 || return 1
  [ "${AWS_EC2_METADATA_DISABLED:-false}" != true ] || return 1
  local token
  token="$(curl -fsS --max-time 1 -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' 2>/dev/null)" || return 1
  curl -fsS --max-time 1 -H "X-aws-ec2-metadata-token: $token" http://169.254.169.254/latest/meta-data/placement/region 2>/dev/null
}

resolve_region(){
  local instance_region
  instance_region="$(detect_imds_region || true)"
  if [ -z "$REGION" ]; then
    [ -n "$instance_region" ] || die "cannot detect EC2 Region; pass --region"
    REGION="$instance_region"
    return 0
  fi
  if [ -n "$instance_region" ] && [ "$REGION" != "$instance_region" ]; then
    die "this EC2 instance is in $instance_region, but the command selected $REGION. Snapshot artifacts require a same-Region S3 gateway endpoint. Re-run with --region $instance_region."
  fi
}

registry_fallback(){
  if [ -n "$REGISTRY_FALLBACK" ]; then echo "$REGISTRY_FALLBACK"
  elif [ -f "$HERE/regions.json" ]; then echo "$HERE/regions.json"
  elif [ -f "$HERE/../landing/config/regions.json" ]; then echo "$HERE/../landing/config/regions.json"
  fi
}

# ── Catalog resolution ───────────────────────────────────────────────────────
resolve_catalog(){
  local fallback; fallback="$(registry_fallback)"
  local args=(resolve --registry "$REGISTRY_URL" --region "$REGION" --output "$RESOLVED_FILE")
  [ -n "$fallback" ] && args+=(--fallback "$fallback")
  [ -n "$SNAPSHOT_ID" ] && args+=(--snapshot "$SNAPSHOT_ID")
  [ -n "$CHAIN" ] && args+=(--chain "$CHAIN")
  [ -n "$NETWORK" ] && args+=(--network "$NETWORK")
  [ -n "$CLIENT" ] && args+=(--client "$CLIENT")
  python3 "$HERE/snapshot-catalog.py" "${args[@]}"
}

list_catalog(){
  local fallback; fallback="$(registry_fallback)"
  local args=(list --registry "$REGISTRY_URL" --region "$REGION")
  [ -n "$fallback" ] && args+=(--fallback "$fallback")
  [ "$JSON_OUTPUT" -eq 1 ] && args+=(--json)
  python3 "$HERE/snapshot-catalog.py" "${args[@]}"
}

json_get(){ python3 "$HERE/snapshot-catalog.py" get "$RESOLVED_FILE" "$1" 2>/dev/null || true; }

load_resolution(){
  SNAPSHOT_ID="$(json_get snapshot.id)"
  CHAIN="$(json_get snapshot.blockchain)"
  NETWORK="$(json_get snapshot.network)"
  CLIENT="$(json_get snapshot.client)"
  PROTOCOL="$(json_get snapshot.delivery.protocol)"
  VERSION_ID="$(json_get snapshot.version.id)"
  SNAPSHOT_URI="$(json_get snapshot.artifacts.full.uri)"
  SNAPSHOT_BUCKET="$(json_get snapshot.artifacts.full.bucket)"
  SNAPSHOT_KEY="$(json_get snapshot.artifacts.full.key)"
  SNAPSHOT_SIZE="$(json_get snapshot.artifacts.full.size_bytes)"
  FULL_FILENAME="$(json_get snapshot.artifacts.full.filename)"
  if [ -z "$SNAPSHOT_URI" ]; then
    SNAPSHOT_URI="$(json_get snapshot.artifacts.snapshot.uri)"
    SNAPSHOT_BUCKET="$(json_get snapshot.artifacts.snapshot.bucket)"
    SNAPSHOT_KEY="$(json_get snapshot.artifacts.snapshot.key)"
    SNAPSHOT_SIZE="$(json_get snapshot.artifacts.snapshot.size_bytes)"
    FULL_FILENAME="$(json_get snapshot.artifacts.snapshot.filename)"
  fi
  MANIFEST_URI="$(json_get snapshot.artifacts.manifest.uri)"
  MANIFEST_KEY="$(json_get snapshot.artifacts.manifest.key)"
  METADATA_URI="$(json_get snapshot.artifacts.metadata.uri)"
  INCREMENTAL_URI="$(json_get snapshot.artifacts.incremental.uri)"
  INCREMENTAL_FILENAME="$(json_get snapshot.artifacts.incremental.filename)"
  GENESIS_URI="$(json_get snapshot.artifacts.genesis.uri)"
  REQUIRED_BYTES="$(json_get snapshot.storage.required_bytes)"
  NORMALIZED_FROM="$(json_get normalized_from)"
  case "$PROTOCOL" in
    tar-zstd-seekable-v1|tar-zstd-stream-v1|archive-set-v1) ;;
    *) die "snapshot uses unsupported delivery protocol '$PROTOCOL'; update the consumer tooling";;
  esac
  [ -n "$OUT" ] || OUT="/data/$SNAPSHOT_ID"
  guard_output_path
  guard_output_contents
  say "resolved $SNAPSHOT_ID latest=${VERSION_ID:-unknown} protocol=$PROTOCOL region=$REGION${NORMALIZED_FROM:+ ($NORMALIZED_FROM adapter)}"
}

load_legacy_parallel(){
  PROTOCOL=tar-zstd-seekable-v1
  SNAPSHOT_ID=legacy-direct
  SNAPSHOT_BUCKET="$BUCKET"
  SNAPSHOT_KEY="$PREFIX/$ARTIFACT"
  SNAPSHOT_URI="s3://$BUCKET/$SNAPSHOT_KEY"
  MANIFEST_KEY="$PREFIX/$MANIFEST"
  MANIFEST_URI="s3://$BUCKET/$MANIFEST_KEY"
  NORMALIZED_FROM=legacy-direct
}

# ── AWS checks and retry ─────────────────────────────────────────────────────
retry_s3(){
  local desc="$1"; shift
  local attempt=1 rc errf; errf="$(mktemp)"
  while :; do
    rc=0; "$@" 2>"$errf" || rc=$?
    if [ "$rc" -eq 0 ]; then rm -f "$errf"; return 0; fi
    if grep -qiE "$S3_PERMANENT_ERRORS" "$errf"; then cat "$errf" >&2; rm -f "$errf"; return "$rc"; fi
    if [ "$attempt" -ge "$RETRY_MAX_ATTEMPTS" ]; then
      echo "ERROR: $desc failed after $attempt attempts (last error below)." >&2; cat "$errf" >&2; rm -f "$errf"; return "$rc"
    fi
    local exp=$(( RETRY_BASE_S * (1 << (attempt - 1)) )); [ "$exp" -gt "$RETRY_CAP_S" ] && exp="$RETRY_CAP_S"
    local sleep_s=$(( RANDOM % (exp + 1) ))
    warn "$desc failed (attempt $attempt/$RETRY_MAX_ATTEMPTS), retrying in ${sleep_s}s"
    sleep "$sleep_s"; attempt=$((attempt + 1))
  done
}

check_credentials(){
  local err="$WORKDIR/sts.err"; say "verifying AWS credentials"
  if retry_s3 "verifying AWS credentials" aws sts get-caller-identity --region "$REGION" >/dev/null 2>"$err"; then return 0; fi
  if grep -qiE 'Could not connect to the endpoint|Connect timeout|Name or service not known|Temporary failure in name resolution' "$err"; then
    warn "could not reach AWS STS; continuing because S3 access is checked next"; return 0
  fi
  echo "ERROR: no usable AWS credentials. On EC2, attach an instance profile that can read the snapshot bucket. In a container, use an ECS task role, EKS Pod Identity/IRSA, AWS_* credentials, or set the EC2 metadata hop limit to 2 for bridge networking. Details:" >&2
  cat "$err" >&2; exit 1
}

check_bucket(){
  local err="$WORKDIR/head-bucket.err"
  if retry_s3 "bucket check" aws s3api head-bucket --bucket "$SNAPSHOT_BUCKET" --region "$REGION" >/dev/null 2>"$err"; then return 0; fi
  if grep -qiE '403|Forbidden|AccessDenied' "$err"; then die "cannot access s3://$SNAPSHOT_BUCKET (403). Check the S3 gateway VPC endpoint and IAM permissions."; fi
  if grep -qiE '404|Not Found|NoSuchBucket' "$err"; then die "catalog points at missing bucket s3://$SNAPSHOT_BUCKET"; fi
  cat "$err" >&2; die "could not reach s3://$SNAPSHOT_BUCKET"
}

head_size(){ retry_s3 "$1" aws s3api head-object --bucket "$2" --key "$3" --region "$REGION" --query ContentLength --output text; }

check_snapshot_object(){
  local size; size="$(head_size 'snapshot check' "$SNAPSHOT_BUCKET" "$SNAPSHOT_KEY")" || die "snapshot object is unavailable: $SNAPSHOT_URI"
  if [ -n "$SNAPSHOT_SIZE" ] && [ "$size" != "$SNAPSHOT_SIZE" ]; then
    die "catalog does not match $SNAPSHOT_URI: catalog size $SNAPSHOT_SIZE, object size $size. Retry after the catalog refreshes."
  fi
  SNAPSHOT_SIZE="$size"
}

# ── Dependencies selected by data ────────────────────────────────────────────
preflight_protocol(){
  local missing=0
  case "$PROTOCOL" in
    tar-zstd-seekable-v1)
      python3 -c 'import zstandard' 2>/dev/null || { echo "ERROR: python zstandard missing (or use --install-deps)" >&2; missing=1; }
      if [ "$READ_VIA" = s3 ]; then python3 -c 'import boto3' 2>/dev/null || { echo "ERROR: python boto3 missing (or use --install-deps)" >&2; missing=1; }; fi;;
    tar-zstd-stream-v1)
      command -v zstd >/dev/null 2>&1 || { echo "ERROR: zstd missing (or use --install-deps)" >&2; missing=1; }
      command -v tar >/dev/null 2>&1 || { echo "ERROR: tar missing (or use --install-deps)" >&2; missing=1; };;
    archive-set-v1) ;;
  esac
  [ "$missing" -eq 0 ] || exit 1
}

# ── Source selection / mount-s3 ──────────────────────────────────────────────
fuse_problem(){
  if [ ! -c "$FUSE_DEV" ]; then echo "$FUSE_DEV is unavailable (container: --device /dev/fuse --cap-add SYS_ADMIN)"
  elif ! command -v mount-s3 >/dev/null 2>&1; then echo "mount-s3 is not installed"
  elif ! command -v fusermount3 >/dev/null 2>&1 && ! command -v fusermount >/dev/null 2>&1; then echo "no FUSE helper is installed"
  fi
}

resolve_source(){
  if [ "$PROTOCOL" = archive-set-v1 ]; then READ_VIA=s3; return; fi
  local why; why="$(fuse_problem)"
  case "$SOURCE" in
    mount) [ -z "$why" ] || die "--source mount: $why; use --source s3"; READ_VIA=mount;;
    s3) READ_VIA=s3;;
    auto) if [ -z "$why" ]; then READ_VIA=mount; else READ_VIA=s3; say "using S3 directly: $why"; fi;;
  esac
}

mount_bucket(){
  MNT_DIR="$WORKDIR/mnt"; mkdir -p "$MNT_DIR"
  say "mounting s3://$SNAPSHOT_BUCKET via mountpoint-s3 (max ${MS3_GBPS} Gbps)"
  if mount-s3 "$SNAPSHOT_BUCKET" "$MNT_DIR" --read-only --maximum-throughput-gbps "$MS3_GBPS" --region "$REGION" 2>"$WORKDIR/mount.err"; then MOUNTED=1; return; fi
  if [ "$SOURCE" = mount ]; then cat "$WORKDIR/mount.err" >&2; die "mount-s3 failed; use --source s3"; fi
  warn "mount-s3 failed ($(tr '\n' ' ' <"$WORKDIR/mount.err" | cut -c1-240)); falling back to S3"
  READ_VIA=s3
  if [ "$PROTOCOL" = tar-zstd-seekable-v1 ]; then python3 -c 'import boto3' 2>/dev/null || die "S3 fallback needs python boto3"; fi
}

unmount_bucket(){
  umount "$MNT_DIR" 2>/dev/null || fusermount3 -u "$MNT_DIR" 2>/dev/null || fusermount -u "$MNT_DIR" 2>/dev/null \
    || { warn "could not unmount $MNT_DIR"; return 1; }
  MOUNTED=0
}

# ── Storage checks ───────────────────────────────────────────────────────────
free_bytes(){ python3 -c 'import os,sys;s=os.statvfs(sys.argv[1]);print(s.f_bavail*s.f_frsize if s.f_blocks else "")' "$1"; }

check_free_space(){
  local required="$1" parent avail; [ -n "$required" ] || return 0
  parent="$(dirname "$OUT")"; mkdir -p "$parent"; avail="$(free_bytes "$parent" 2>/dev/null || true)"
  if [ -n "$avail" ] && [ "$avail" -lt "$required" ]; then die "not enough free space at $parent: need $(human_size "$required"), have $(human_size "$avail")"; fi
}

drop_page_cache(){ sync; { echo 3 > /proc/sys/vm/drop_caches; } 2>/dev/null || warn "could not drop page cache"; }

# ── Protocol: tar-zstd-seekable-v1 ──────────────────────────────────────────
manifest_summary(){
  python3 - "$1" <<'PY'
import json,sys
try:
    m=json.load(open(sys.argv[1])); print(int(m['frame_count']),int(m['uncompressed_size']),m.get('compressed_size') or '')
except (OSError,ValueError,KeyError,TypeError) as e: sys.exit(f'{type(e).__name__}: {e}')
PY
}

run_seekable(){
  local summary frames usize csize actual t0=$SECONDS
  say "fetching seekable manifest $MANIFEST_URI"
  retry_s3 "manifest fetch" aws s3 cp "$MANIFEST_URI" "$WORKDIR/manifest.json" --region "$REGION" --only-show-errors \
    || die "cannot fetch required manifest $MANIFEST_URI"
  summary="$(manifest_summary "$WORKDIR/manifest.json")" || die "manifest is malformed or missing required fields"
  read -r frames usize csize <<<"$summary"
  actual="$(head_size 'snapshot check' "$SNAPSHOT_BUCKET" "$SNAPSHOT_KEY")" || die "snapshot unavailable: $SNAPSHOT_URI"
  [ -z "$SNAPSHOT_SIZE" ] || [ "$actual" = "$SNAPSHOT_SIZE" ] || die "catalog snapshot size is stale; reload and retry"
  [ -z "$csize" ] || [ "$actual" = "$csize" ] || die "manifest does not match the snapshot object"
  check_free_space "$usize"
  [ "$READ_VIA" = mount ] && mount_bucket
  rm -rf "${OUT:?}"; mkdir -p "$OUT"
  [ "$DROP_CACHES" = 1 ] && drop_page_cache
  EXTRACT_CMD=(python3 "$HERE/snapshot-extract.py" --index "$WORKDIR/manifest.json" --out "$OUT" --workers "$WORKERS" --o-direct "$ODIRECT")
  if [ "$READ_VIA" = mount ]; then EXTRACT_CMD+=(--local "$MNT_DIR/$SNAPSHOT_KEY")
  else EXTRACT_CMD+=(--s3 "$SNAPSHOT_BUCKET" "$SNAPSHOT_KEY" --region "$REGION"); fi
  [ "$DEBUG" = 1 ] && EXTRACT_CMD+=(--verbose)
  say "extracting $frames frames ($READ_VIA) -> $OUT"
  "${EXTRACT_CMD[@]}" >"$WORKDIR/extract-result.json"
  [ "$JSON_OUTPUT" -eq 1 ] || cat "$WORKDIR/extract-result.json"
  finish_success "$t0" "$actual" "$READ_VIA"
}

# ── Protocol: tar-zstd-stream-v1 ────────────────────────────────────────────
run_stream(){
  local t0=$SECONDS
  check_snapshot_object
  [ -n "$REQUIRED_BYTES" ] || REQUIRED_BYTES=$((SNAPSHOT_SIZE * 2))
  check_free_space "$REQUIRED_BYTES"
  [ "$READ_VIA" = mount ] && mount_bucket
  rm -rf "${OUT:?}"; mkdir -p "$OUT"
  [ "$DROP_CACHES" = 1 ] && drop_page_cache
  say "streaming and extracting ($READ_VIA) -> $OUT"
  if [ "$READ_VIA" = mount ]; then
    zstd -dc --long=27 "$MNT_DIR/$SNAPSHOT_KEY" | tar xf - -C "$OUT" --no-same-owner
  else
    aws s3 cp "$SNAPSHOT_URI" - --region "$REGION" --cli-read-timeout 0 --only-show-errors | zstd -d --long=27 | tar xf - -C "$OUT" --no-same-owner
  fi
  finish_success "$t0" "$SNAPSHOT_SIZE" "$READ_VIA"
}

# ── Protocol: archive-set-v1 ────────────────────────────────────────────────
safe_filename(){
  python3 - "$1" <<'PY'
import os,sys
value=sys.argv[1]
if not value or value in ('.','..') or os.path.basename(value)!=value or '\0' in value:
    raise SystemExit(1)
PY
}

load_archive_metadata(){
  if [ -z "$FULL_FILENAME" ]; then
    [ -n "$METADATA_URI" ] || die "archive-set catalog has no full filename or metadata artifact"
    retry_s3 "archive metadata fetch" aws s3 cp "$METADATA_URI" "$WORKDIR/archive-meta.json" --region "$REGION" --only-show-errors \
      || die "cannot fetch archive metadata $METADATA_URI"
    FULL_FILENAME="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["full"]["filename"])' "$WORKDIR/archive-meta.json")" \
      || die "archive metadata has no full filename"
    if [ -z "$INCREMENTAL_FILENAME" ]; then
      INCREMENTAL_FILENAME="$(python3 -c 'import json,sys;m=json.load(open(sys.argv[1])).get("incremental");print(m.get("filename","") if m else "")' "$WORKDIR/archive-meta.json")"
    fi
  fi
  safe_filename "$FULL_FILENAME" || die "archive full filename is unsafe: '$FULL_FILENAME'"
  if [ -n "$INCREMENTAL_FILENAME" ]; then
    safe_filename "$INCREMENTAL_FILENAME" || die "archive incremental filename is unsafe: '$INCREMENTAL_FILENAME'"
  fi
}

download_optional(){
  local uri="$1" dest="$2" label="$3"; [ -n "$uri" ] || return 0
  if ! retry_s3 "$label" aws s3 cp "$uri" "$dest" --region "$REGION" --only-show-errors; then warn "$label unavailable; continuing"; return 0; fi
}

run_archive_set(){
  local t0=$SECONDS
  check_snapshot_object
  load_archive_metadata
  [ -n "$REQUIRED_BYTES" ] || REQUIRED_BYTES=$((SNAPSHOT_SIZE * 105 / 100))
  check_free_space "$REQUIRED_BYTES"
  mkdir -p "$OUT"
  say "downloading full archive -> $OUT/$FULL_FILENAME"
  retry_s3 "full archive download" aws s3 cp "$SNAPSHOT_URI" "$OUT/$FULL_FILENAME" --region "$REGION" --only-show-errors \
    || die "full archive download failed"
  if [ -n "$INCREMENTAL_URI" ] && [ -n "$INCREMENTAL_FILENAME" ]; then
    say "downloading incremental archive -> $OUT/$INCREMENTAL_FILENAME"
    download_optional "$INCREMENTAL_URI" "$OUT/$INCREMENTAL_FILENAME" "incremental archive download"
  fi
  download_optional "$GENESIS_URI" "$OUT/genesis.tar.bz2" "genesis download"
  finish_success "$t0" "$SNAPSHOT_SIZE" archive-set
}

finish_success(){
  local started="$1" size="$2" method="$3"
  local duration=$((SECONDS-started))
  if [ "$JSON_OUTPUT" -eq 1 ]; then
    python3 - "$SNAPSHOT_ID" "$CHAIN" "$NETWORK" "$CLIENT" "$VERSION_ID" "$PROTOCOL" "$REGION" "$OUT" "$size" "$duration" "$method" "$FULL_FILENAME" "$INCREMENTAL_FILENAME" <<'PY'
import json,sys
(snapshot_id,blockchain,network,client,version,protocol,region,out,size,duration,
 method,full_filename,incremental_filename)=sys.argv[1:]
def number(value):
    try: return int(value)
    except ValueError: return value
result={
    'status':'success','snapshot_id':snapshot_id,'blockchain':blockchain,
    'network':network,'client':client,'version':version,'block':version,
    'delivery_protocol':protocol,'region':region,'output_dir':out,
    'size_bytes':number(size),'duration_seconds':number(duration),'method':method,
}
if full_filename: result['full_filename']=full_filename
if incremental_filename: result['incremental_filename']=incremental_filename
print(json.dumps(result,separators=(',',':')))
PY
  else
    say "snapshot ready at $OUT in ${duration}s"
  fi
}

cleanup(){
  [ "$MOUNTED" -eq 1 ] && unmount_bucket || true
  if [ -z "$WORKDIR" ] || [ ! -d "$WORKDIR" ]; then return 0; fi
  if [ "$DEBUG" = 1 ]; then echo "DEBUG: kept work dir $WORKDIR" >&2; else rm -rf "$WORKDIR" || true; fi
}

warn_if_sudo_download(){
  if [ "$SETUP_ONLY" -eq 0 ] && [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER:-}" != root ]; then
    warn "snapshot.sh was invoked through sudo; output will be owned by root. Run the download without sudo after setup, or run it as the node service user."
  fi
}

main(){
  set -euo pipefail
  export PATH="$PATH:/usr/local/bin:/usr/sbin:/usr/bin:/bin"
  HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
  parse_args "$@"
  [ "$DEBUG" = 1 ] && set -x
  warn_if_sudo_download
  guard_output_path  # explicit dangerous --out is refused before dependencies/network
  if [ "$LEGACY_PARALLEL" -eq 1 ]; then
    PROTOCOL=tar-zstd-seekable-v1
    guard_output_contents
  fi
  make_workdir; trap cleanup EXIT
  [ "$INSTALL_DEPS" -eq 1 ] && install_deps
  if [ "$SETUP_ONLY" -eq 1 ]; then
    preflight_setup
    return 0
  fi
  preflight_resolver
  resolve_region

  export AWS_RETRY_MODE="${AWS_RETRY_MODE:-adaptive}"
  export AWS_MAX_ATTEMPTS="${AWS_MAX_ATTEMPTS:-6}"

  if [ "$LEGACY_PARALLEL" -eq 1 ]; then
    preflight_aws
    load_legacy_parallel
    guard_output_contents
  elif [ "$LIST_ONLY" -eq 1 ]; then
    list_catalog; return 0
  else
    resolve_catalog
    load_resolution
    preflight_aws
  fi

  check_credentials
  check_bucket
  resolve_source
  preflight_protocol

  case "$PROTOCOL" in
    tar-zstd-seekable-v1) run_seekable;;
    tar-zstd-stream-v1) run_stream;;
    archive-set-v1) run_archive_set;;
    *) die "unsupported delivery protocol '$PROTOCOL'; update the consumer tooling";;
  esac
}

if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then main "$@"; fi
