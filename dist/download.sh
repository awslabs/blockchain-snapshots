#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
# Compatibility shim. The public entrypoint is snapshot.sh.
#
# Legacy forms retained for one migration release:
#   download.sh [options] <snapshot-id> <out>
#   download.sh [options] <network> <client> <out>             (Ethereum)
#   download.sh [options] <blockchain> <network> <client> <out>
#
# Snapshot validity is no longer hardcoded here: selectors are resolved from
# the regional catalog by snapshot.sh.

_SHIM_DIR="${BASH_SOURCE[0]:-$0}"
_SHIM_DIR="${_SHIM_DIR%/*}"
[ "$_SHIM_DIR" = "${BASH_SOURCE[0]:-$0}" ] && _SHIM_DIR=.

if [[ "${BASH_SOURCE[0]:-$0}" != "$0" ]]; then
  # shellcheck source=snapshot.sh
  source "$_SHIM_DIR/snapshot.sh"
  return 0
fi

set -euo pipefail

usage(){
  cat <<'EOF'
DEPRECATED: use snapshot.sh.

Legacy usage:
  download.sh [OPTIONS] <snapshot-id> <output_dir>
  download.sh [OPTIONS] <network> <client> <output_dir>
  download.sh [OPTIONS] <blockchain> <network> <client> <output_dir>

Options forwarded: --region, --json, --install-deps, --force
The old --block option is removed: snapshot.sh always resolves latest.
EOF
}

ARGS=()
POSITIONAL=()
while [ $# -gt 0 ]; do
  case "$1" in
    --region) [ $# -ge 2 ] || { echo "ERROR: --region needs a value" >&2; exit 2; }; ARGS+=(--region "$2"); shift 2;;
    --json|--install-deps|--force) ARGS+=("$1"); shift;;
    --block) echo "ERROR: --block is no longer supported; snapshot.sh always resolves the latest catalog version." >&2; exit 2;;
    -h|--help) usage; exit 0;;
    -*) echo "ERROR: unknown legacy option: $1" >&2; exit 2;;
    *) POSITIONAL+=("$1"); shift;;
  esac
done

if [ -n "${STAGE:-}" ] && [ "${STAGE:-}" != production ]; then
  echo "ERROR: legacy STAGE is not supported by the production registry. Use snapshot.sh --registry <url>." >&2
  exit 2
fi

case "${#POSITIONAL[@]}" in
  2) ARGS+=(--snapshot "${POSITIONAL[0]}" --out "${POSITIONAL[1]}");;
  3) ARGS+=(--chain ethereum --network "${POSITIONAL[0]}" --client "${POSITIONAL[1]}" --out "${POSITIONAL[2]}");;
  4) ARGS+=(--chain "${POSITIONAL[0]}" --network "${POSITIONAL[1]}" --client "${POSITIONAL[2]}" --out "${POSITIONAL[3]}");;
  *) usage >&2; exit 2;;
esac

echo "WARN: download.sh is deprecated; use snapshot.sh --snapshot <id>." >&2
exec "$_SHIM_DIR/snapshot.sh" "${ARGS[@]}"
