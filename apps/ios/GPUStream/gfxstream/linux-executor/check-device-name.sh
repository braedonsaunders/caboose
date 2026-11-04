#!/bin/sh
# check-device-name.sh WORK: the device-name layer of a Linux executor build (WORK/build) makes
# the executor's Vulkan loader report "Caboose Linux executor" in place of lavapipe's
# "llvmpipe (...)", and CABOOSE_EXECUTOR_KEEP_DEVICE_NAME=1 turns it off (README.md, "The
# device name"). Runs vulkaninfo in the caboose-linux-executor image, without network.
set -eu
[ $# -eq 1 ] || { echo "usage: $0 WORK" >&2; exit 2; }
work=$(cd "$1" && pwd)
here=$(cd "$(dirname "$0")" && pwd)
docker run --rm --network none --cpus 2 -v "$work/build:/build:ro" -v "$here:/executor:ro" --entrypoint python3 \
  caboose-linux-executor - <<'PY'
import os, subprocess, sys
sys.path.insert(0, '/executor')
sys.argv = ['executor.py']
import executor
def name():
    out = subprocess.run(['vulkaninfo', '--summary'], capture_output=True, text=True, check=True).stdout
    return [l.split('=', 1)[1].strip() for l in out.splitlines() if 'deviceName' in l]
assert executor.name_device('/build/libcaboose_gpu_executor.so', executor.DEVICE_NAME), 'no layer beside the library'
renamed = name()
os.environ['CABOOSE_EXECUTOR_KEEP_DEVICE_NAME'] = '1'
kept = name()
ok = renamed and all(n == executor.DEVICE_NAME for n in renamed) and kept and all('llvmpipe' in n for n in kept)
print(('PASS' if ok else 'FAIL') + f' device name: reported {renamed}, without the layer {kept}')
sys.exit(0 if ok else 1)
PY
