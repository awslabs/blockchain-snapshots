#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
# Compatibility shim. The public entrypoint is snapshot.sh.
#
# Existing automation may keep using:
#   download-and-unpack.sh --bucket B --prefix P [legacy options]
# for one migration release. It is forwarded to snapshot.sh's exact-artifact
# seekable path. New callers should select a catalog ID with snapshot.sh.

_SHIM_DIR="${BASH_SOURCE[0]:-$0}"
_SHIM_DIR="${_SHIM_DIR%/*}"
[ "$_SHIM_DIR" = "${BASH_SOURCE[0]:-$0}" ] && _SHIM_DIR=.

if [[ "${BASH_SOURCE[0]:-$0}" != "$0" ]]; then
  # Preserve sourceability for operators/tests that call helper functions.
  # shellcheck source=snapshot.sh
  source "$_SHIM_DIR/snapshot.sh"
else
  echo "WARN: download-and-unpack.sh is deprecated; use snapshot.sh --snapshot <id>." >&2
  exec "$_SHIM_DIR/snapshot.sh" --legacy-parallel "$@"
fi
