#!/bin/sh
# Install the live GPU broker and, where present, the phone's Vulkan driver and its layers
# (install-live.py, docs/gpu-live.md).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
python3 "$here/install-live.py"
