#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
# setup-storage.sh — RAID-0 the instance-store NVMe drives and mount at /data.
# Run ON the instance, as root, BEFORE download-and-unpack.sh. Idempotent and
# observable (unlike fire-and-forget cloud-init): prints what it does and fails
# loud if /data does not end up on the big instance-store volume.
set -uo pipefail
export PATH=/usr/sbin:/usr/local/bin:/usr/bin:/bin:$PATH

MNT="${MNT:-/data}"
say(){ echo "[setup-storage] $*"; }

# Already set up? (idempotent — safe to re-run)
if mountpoint -q "$MNT"; then
  GB=$(df -BG --output=size "$MNT" 2>/dev/null | tail -1 | tr -dc '0-9')
  if [ "${GB:-0}" -ge 100 ]; then
    say "$MNT already mounted (${GB}G) — nothing to do"
    exit 0
  fi
  say "WARNING: $MNT mounted but only ${GB}G — not the instance-store array"
fi

command -v mdadm >/dev/null || {
  say "installing mdadm/xfsprogs...";
  if command -v apt-get >/dev/null; then
    DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y mdadm xfsprogs >/dev/null 2>&1
  elif command -v dnf >/dev/null; then dnf install -y mdadm xfsprogs >/dev/null 2>&1
  elif command -v yum >/dev/null; then yum install -y mdadm xfsprogs >/dev/null 2>&1
  fi
}

# Find instance-store NVMe (exclude the root EBS volume).
NV=$(lsblk -dn -o NAME,MODEL | awk '/Instance Storage/{print "/dev/"$1}')
NDISK=$(echo $NV | wc -w)
say "instance-store NVMe found: $NDISK device(s): $NV"
[ "$NDISK" -lt 1 ] && { say "ERROR: no instance-store NVMe found"; exit 1; }

if [ "$NDISK" -ge 2 ]; then
  mdadm --stop /dev/md0 2>/dev/null || true
  say "creating RAID-0 across $NDISK drives..."
  mdadm --create /dev/md0 --level=0 --raid-devices="$NDISK" --chunk=256 $NV --run --force
  # let the array settle before mkfs
  sleep 3
  udevadm settle 2>/dev/null || true
  DEV=/dev/md0
else
  DEV=$NV
  say "single NVMe — using $DEV directly (no RAID)"
fi

say "mkfs.xfs on $DEV..."
mkfs.xfs -f -d su=256k,sw="$NDISK" "$DEV" >/dev/null 2>&1 || mkfs.xfs -f "$DEV" >/dev/null
mkdir -p "$MNT"
mount -o noatime "$DEV" "$MNT"
chmod 777 "$MNT"
mkdir -p "$MNT/opt"

GB=$(df -BG --output=size "$MNT" 2>/dev/null | tail -1 | tr -dc '0-9')
if mountpoint -q "$MNT" && [ "${GB:-0}" -ge 100 ]; then
  say "OK: $MNT is ${GB}G on $DEV ($NDISK NVMe)"
else
  say "ERROR: $MNT did not end up on the big array (size=${GB:-0}G)"; exit 1
fi
