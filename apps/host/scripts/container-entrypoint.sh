#!/usr/bin/env bash
set -euo pipefail
CABOOSE_NO_FSTAB=1 setup-disks "$CABOOSE_IMAGE_ROOT" "${CABOOSE_DISK_SIZE:-400G}"
exec "$@"
