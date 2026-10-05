#!/usr/bin/env bash
# Generates landing/catalog-endpoints.json from the deployed CloudFormation stacks.
#
# Reads config/regions.json (region codes only) and for each region, queries the
# CatalogUrl output of the deployed stack. Regions whose stack or catalog CDN
# isn't deployed yet are left out of the file (and listed on stderr), so the
# published page only ever shows live regions.
#
# Usage:
#   ./build-endpoints.sh --stage staging [--profile <your-aws-profile>]
#   ./build-endpoints.sh --stage production --profile <your-aws-profile>
#
# The output (catalog-endpoints.json) is gitignored — it never carries staging
# URLs into a production repo or vice versa.

set -euo pipefail

STAGE=""
PROFILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --stage)   STAGE="$2"; shift 2;;
    --profile) PROFILE="$2"; shift 2;;
    *) echo "unknown: $1"; exit 1;;
  esac
done

if [[ -z "$STAGE" ]]; then
  echo "usage: $0 --stage <staging|production> [--profile <aws-profile>]"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REGIONS_FILE="$SCRIPT_DIR/../config/regions.json"
OUT="$SCRIPT_DIR/catalog-endpoints.json"

if [[ ! -f "$REGIONS_FILE" ]]; then
  echo "error: $REGIONS_FILE not found"
  exit 1
fi

REGIONS=$(node -e "console.log(require('$REGIONS_FILE').regions.join(' '))")

AWS_OPTS=""
[[ -n "$PROFILE" ]] && AWS_OPTS="--profile $PROFILE"

# Fail fast on environment problems instead of mapping them to "not deployed":
# without these checks, expired creds or a missing CLI would silently produce an
# empty endpoints file (every region skipped) with exit 0.
command -v aws  >/dev/null || { echo "error: aws CLI not found"; exit 1; }
command -v node >/dev/null || { echo "error: node not found"; exit 1; }
aws sts get-caller-identity $AWS_OPTS >/dev/null 2>&1 \
  || { echo "error: AWS credentials invalid/expired (profile: ${PROFILE:-default})"; exit 1; }

echo '{ "regions": [' > "$OUT"
first=true
written=0
skipped=""
for R in $REGIONS; do
  STACK="snapshot-standard-${STAGE}-${R}"
  # Capture stderr so we can tell "stack doesn't exist" (→ skip) apart from
  # every other failure (auth, network, throttle → abort; see check above).
  ERR=$(mktemp)
  URL=$(aws cloudformation describe-stacks \
    --region "$R" --stack-name "$STACK" \
    --query "Stacks[0].Outputs[?OutputKey=='CatalogUrl'].OutputValue" \
    --output text $AWS_OPTS 2>"$ERR") || {
      if grep -q "does not exist" "$ERR"; then
        URL=""
      else
        echo "error: describe-stacks failed for $STACK in $R:" >&2
        cat "$ERR" >&2
        rm -f "$ERR"
        exit 1
      fi
    }
  rm -f "$ERR"
  # Empty output or "None" means the catalog isn't deployed yet: leave it out.
  if [[ -z "$URL" || "$URL" == "None" ]]; then
    skipped="$skipped $R"
    continue
  fi
  $first || echo ',' >> "$OUT"
  printf '  { "code": "%s", "catalogUrl": "%s" }' "$R" "$URL" >> "$OUT"
  first=false
  written=$((written + 1))
done
echo '' >> "$OUT"
echo '] }' >> "$OUT"

echo "wrote $OUT (stage=$STAGE, $written of $(echo "$REGIONS" | wc -w | tr -d ' ') regions)"
if [[ -n "$skipped" ]]; then
  echo "skipped (catalog not deployed):$skipped" >&2
fi
cat "$OUT"
