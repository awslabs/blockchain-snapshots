#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
# Regenerate config/regions.json, the public active-region registry consumed by
# both the landing page and dist/snapshot.sh.
#
# Reads candidate region codes from ../config/regions.json, queries the deployed
# CloudFormation stacks, and emits ONLY regions with both CatalogUrl and
# BucketName outputs. This is a read-only operation; it does not deploy AWS
# resources. Production output is committed/published with the landing page.
#
# Usage:
#   ./build-endpoints.sh --stage production [--profile PROFILE] [--out FILE]

set -euo pipefail
STAGE=""
PROFILE=""
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="$SCRIPT_DIR/config/regions.json"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --stage) STAGE="$2"; shift 2;;
    --profile) PROFILE="$2"; shift 2;;
    --out) OUT="$2"; shift 2;;
    *) echo "unknown argument: $1" >&2; exit 2;;
  esac
done
[[ -n "$STAGE" ]] || { echo "usage: $0 --stage <stage> [--profile PROFILE] [--out FILE]" >&2; exit 2; }

CANDIDATES="$SCRIPT_DIR/../config/regions.json"
[[ -f "$CANDIDATES" ]] || { echo "error: $CANDIDATES not found" >&2; exit 1; }
command -v aws >/dev/null || { echo "error: aws CLI not found" >&2; exit 1; }
command -v python3 >/dev/null || { echo "error: python3 not found" >&2; exit 1; }

AWS_OPTS=()
[[ -n "$PROFILE" ]] && AWS_OPTS+=(--profile "$PROFILE")
aws sts get-caller-identity "${AWS_OPTS[@]}" >/dev/null 2>&1 \
  || { echo "error: AWS credentials invalid/expired (profile: ${PROFILE:-default})" >&2; exit 1; }

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
python3 - "$CANDIDATES" >"$TMP" <<'PY'
import json,sys
for region in json.load(open(sys.argv[1]))['regions']:
    print(region)
PY

mkdir -p "$(dirname "$OUT")"
RESULT="$(mktemp)"
trap 'rm -f "$TMP" "$RESULT"' EXIT
printf '{\n  "schema_version": 1,\n  "regions": [\n' >"$RESULT"
first=1
written=0
while IFS= read -r region; do
  stack="snapshot-standard-${STAGE}-${region}"
  outputs="$(aws cloudformation describe-stacks --region "$region" --stack-name "$stack" \
    --query 'Stacks[0].Outputs[].[OutputKey,OutputValue]' --output text "${AWS_OPTS[@]}" 2>/dev/null || true)"
  catalog_url="$(printf '%s\n' "$outputs" | awk '$1=="CatalogUrl" {$1=""; sub(/^ /,""); print; exit}')"
  bucket="$(printf '%s\n' "$outputs" | awk '$1=="BucketName" {$1=""; sub(/^ /,""); print; exit}')"
  [[ -n "$catalog_url" && "$catalog_url" != None && -n "$bucket" && "$bucket" != None ]] || continue
  name="$(python3 - "$region" <<'PY'
import sys
names={'us-east-1':'US East (N. Virginia)','eu-west-1':'Europe (Ireland)','ap-northeast-1':'Asia Pacific (Tokyo)'}
print(names.get(sys.argv[1],sys.argv[1]))
PY
)"
  [[ "$first" -eq 1 ]] || printf ',\n' >>"$RESULT"
  python3 - "$region" "$name" "$catalog_url" "$bucket" >>"$RESULT" <<'PY'
import json,sys
region,name,url,bucket=sys.argv[1:]
value={'code':region,'name':name,'catalog_url':url,
       'catalog_s3_uri':f's3://{bucket}/catalog.json'}
print('    '+json.dumps(value,separators=(',',': ')),end='')
PY
  first=0
  written=$((written+1))
done <"$TMP"
printf '\n  ]\n}\n' >>"$RESULT"

[[ "$written" -gt 0 ]] || { echo "error: no active regional catalogs found; refusing to overwrite $OUT" >&2; exit 1; }
mv "$RESULT" "$OUT"
trap 'rm -f "$TMP"' EXIT
echo "wrote $OUT ($written active regions, stage=$STAGE)"
cat "$OUT"
