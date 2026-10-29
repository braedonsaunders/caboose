#!/usr/bin/env bash
# Sourced by the image builder and scratch-loop check. All sizes are bytes or
# explicitly named 512-byte sectors. The final 33 sectors hold the backup GPT.
CABOOSE_DISK_BYTES=$((60 * 1024 * 1024 * 1024))
CABOOSE_ROOT_START=6144
CABOOSE_ROOT_SECTORS=$((CABOOSE_DISK_BYTES / 512 - CABOOSE_ROOT_START - 33))
# Used by callers when mounting the root.
# shellcheck disable=SC2034
CABOOSE_ROOT_OPTIONS=compress-force=zstd:1,discard=async,noatime

create_root_disk() {
  # Noclobber refuses existing disks, including symlinks; no conversion path.
  (set -o noclobber; : > "$1") || return 1
  truncate -s "$CABOOSE_DISK_BYTES" "$1"
  sfdisk "$1" <<PARTS
label: gpt
unit: sectors
sector-size: 512
start=2048, size=2048, type=linux
start=4096, size=2048, type=linux
start=$CABOOSE_ROOT_START, size=$CABOOSE_ROOT_SECTORS, type=linux
PARTS
}

attach_root_disk() {
  losetup --find --show --offset "$((CABOOSE_ROOT_START * 512))" \
    --sizelimit "$((CABOOSE_ROOT_SECTORS * 512))" "$1"
}
