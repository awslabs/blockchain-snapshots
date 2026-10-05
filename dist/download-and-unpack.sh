#!/bin/bash
# download-and-unpack.sh — fast parallel download + decompress + extract of a
# repackaged snapshot (the producer published snapshot.tar.zst +
# download-manifest.json). Run ON the provisioned instance.
#
# Pipeline: mount-s3 (parallel byte-range download) | manifest-driven
# frame-parallel decode | O_DIRECT parallel writes. ~70s for 765 GB on
# i8g.24xlarge; ~132s on i8g.12xlarge. Byte-identical to a serial tar -x.
#
# Account-agnostic — point it at any bucket/prefix you can read:
#   BUCKET   --bucket    REQUIRED  (e.g. public-blockchain-snapshots-<region>)
#   PREFIX   --prefix    REQUIRED  (path to the artifact dir, e.g.
#                        ethereum/mainnet/reth/<block>)
#   REGION   --region    default us-east-1
#   OUT      --out       default /data/extract
#   WORKERS  --workers   default 0 = min(nproc, 96)  [96 = mountpoint sweet spot]
#   ARTIFACT --artifact  default snapshot.tar.zst
#   MANIFEST --manifest  default download-manifest.json
set -euo pipefail
export PATH=/usr/local/bin:/usr/sbin:/usr/bin:/bin:$PATH

BUCKET="${BUCKET:-}"
PREFIX="${PREFIX:-}"
REGION="${REGION:-us-east-1}"
OUT="${OUT:-/data/extract}"
WORKERS="${WORKERS:-0}"
ARTIFACT="${ARTIFACT:-snapshot.tar.zst}"
MANIFEST="${MANIFEST:-download-manifest.json}"
HERE="$(cd "$(dirname "$0")" && pwd)"

while [ $# -gt 0 ]; do
  case "$1" in
    --bucket) BUCKET="$2"; shift 2;;
    --prefix) PREFIX="$2"; shift 2;;
    --region) REGION="$2"; shift 2;;
    --out) OUT="$2"; shift 2;;
    --workers) WORKERS="$2"; shift 2;;
    --artifact) ARTIFACT="$2"; shift 2;;
    --manifest) MANIFEST="$2"; shift 2;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done
[ -z "$BUCKET" ] && { echo "ERROR: --bucket required" >&2; exit 2; }
[ -z "$PREFIX" ] && { echo "ERROR: --prefix required (artifact dir, e.g. ethereum/mainnet/reth/<block>)" >&2; exit 2; }

command -v mount-s3 >/dev/null || { echo "ERROR: mount-s3 not installed (run provisioning first)" >&2; exit 1; }
command -v python3   >/dev/null || { echo "ERROR: python3 missing" >&2; exit 1; }
python3 -c "import zstandard" 2>/dev/null || { echo "ERROR: pip install zstandard" >&2; exit 1; }

say(){ echo "[$(date -u +%H:%M:%S)] $*"; }

# 1) fetch the manifest (small) directly
mkdir -p "$(dirname "$OUT")" /tmp/dl-manifest
say "fetching manifest s3://$BUCKET/$PREFIX/$MANIFEST"
aws s3 cp "s3://$BUCKET/$PREFIX/$MANIFEST" /tmp/dl-manifest/manifest.json --region "$REGION" --no-progress
FR=$(python3 -c "import json;print(json.load(open('/tmp/dl-manifest/manifest.json'))['frame_count'])")
US=$(python3 -c "import json;print(json.load(open('/tmp/dl-manifest/manifest.json'))['uncompressed_size'])")
say "manifest: $FR frames, $(( US/1024/1024/1024 )) GiB uncompressed"

# 2) mount the bucket (mountpoint-s3 = parallel byte-range download under the hood)
MNT=/mnt/snapshot-src
mkdir -p "$MNT"; mountpoint -q "$MNT" && umount "$MNT" || true
say "mounting bucket via mountpoint-s3"
mount-s3 "$BUCKET" "$MNT" --read-only --maximum-throughput-gbps 100 --region "$REGION"

# 3) parallel extract: manifest-driven, frame-parallel decode + O_DIRECT writes
rm -rf "$OUT"; mkdir -p "$OUT"
sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
say "extracting (workers=$WORKERS, O_DIRECT) -> $OUT"
t0=$SECONDS
python3 "$HERE/snapshot-extract.py" --index /tmp/dl-manifest/manifest.json \
   --out "$OUT" --workers "$WORKERS" --local "$MNT/$PREFIX/$ARTIFACT" --o-direct
say "extract done in $((SECONDS-t0))s"
umount "$MNT" 2>/dev/null || true
say "snapshot ready at $OUT"
