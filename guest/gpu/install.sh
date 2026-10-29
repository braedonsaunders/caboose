#!/bin/sh
# Install caboose-gpu-run. The driver and layers it loads are built into the images
# (/usr/local/lib/caboose-gpu, from build.sh).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
install -Dm755 "$here/caboose-gpu-run" /usr/local/bin/caboose-gpu-run
if [ -d /usr/local/lib/caboose-gpu ]; then
  install -m 644 "$here/profile.json" /usr/local/lib/caboose-gpu/profile.json
fi
