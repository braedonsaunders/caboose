#!/usr/bin/env bash
set -euo pipefail
: "${CABOOSE_OWNER_TOKEN:?CABOOSE_OWNER_TOKEN must be set}"
CABOOSE_NO_FSTAB=1 setup-disks "$CABOOSE_IMAGE_ROOT" "${CABOOSE_DISK_SIZE:-400G}"
exec "$@"
