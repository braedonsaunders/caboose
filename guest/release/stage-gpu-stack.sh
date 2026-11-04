#!/bin/sh
# The computer's whole GPU stack as a release carries it, staged under OUT from a checkout and
# built pieces, so that a release installs it on a computer that has none of it (README.md,
# "The GPU stack"):
#
#   sh guest/release/stage-gpu-stack.sh REPO DRIVER_DIR LAYERS_DIR WARMUP_DIR GBM OUT
#
# DRIVER_DIR is the guest driver build's output (libvulkan_gfxstream.so, i386/ and
# caboose-driver.json); LAYERS_DIR holds the implicit layers, libVkLayer_caboose_executor_switch.so
# and libVkLayer_caboose_gpu_routing.so, with their i386 builds in i386/; WARMUP_DIR holds the
# built caboose-gpu-warmup; GBM is the built vgem_gbm.so. install-live.py places them all (the
# broker and its modules, the driver, both layers and their loader manifests for the computer
# and for each Flatpak "host" GL extension, the GBM backend, the driconf entry and the global
# Flatpak override), then the driver's build record and the capability warm-up are added.
# Add every file under OUT to a release with `caboose-release add` at its path and mode.
set -eu
[ $# -eq 6 ] || { sed -n '4,17p' "$0" >&2; exit 2; }
repo=$(cd "$1" && pwd)
driver=$(cd "$2" && pwd)
layers=$(cd "$3" && pwd)
warmup=$(cd "$4" && pwd)
gbm=$(realpath "$5")
out=$6
[ ! -e "$out" ] || [ -z "$(ls -A "$out")" ] || { echo "$out is not empty" >&2; exit 1; }
mkdir -p "$out"
out=$(cd "$out" && pwd)
for f in "$driver/libvulkan_gfxstream.so" "$driver/i386/libvulkan_gfxstream.so" "$driver/caboose-driver.json" \
         "$layers/libVkLayer_caboose_executor_switch.so" "$layers/i386/libVkLayer_caboose_executor_switch.so" \
         "$layers/libVkLayer_caboose_gpu_routing.so" "$layers/i386/libVkLayer_caboose_gpu_routing.so" \
         "$warmup/caboose-gpu-warmup" "$gbm"; do
  [ -f "$f" ] || { echo "missing $f" >&2; exit 1; }
done
python3 -I "$repo/guest/gpu/install-live.py" --source-root "$repo/guest/gpu" --destdir "$out" --machine x86_64 \
  --gbm "$gbm" \
  --driver "$driver/libvulkan_gfxstream.so" --driver "$driver/i386/libvulkan_gfxstream.so" \
  --executor-switch "$layers/libVkLayer_caboose_executor_switch.so" --executor-switch "$layers/i386/libVkLayer_caboose_executor_switch.so" \
  --routing-layer "$layers/libVkLayer_caboose_gpu_routing.so" --routing-layer "$layers/i386/libVkLayer_caboose_gpu_routing.so"
# put MODE SOURCE PATH: SOURCE at OUT/PATH.
put() { mkdir -p "$(dirname "$out/$3")" && cp "$2" "$out/$3" && chmod "$1" "$out/$3"; }
live=usr/local/lib/caboose-gpu-live
host=var/lib/flatpak/extension/org.freedesktop.Platform.GL.host/x86_64/1.4
put 0644 "$driver/caboose-driver.json" "$live/caboose-driver.json"
# The computer's own vgem GBM backend beside Mesa's (Flatpak applications get theirs in GL.host).
put 0644 "$gbm" usr/lib/x86_64-linux-gnu/gbm/vgem_gbm.so
# The capability warm-up: the session runs it, and Flatpak applications' first start finds it in GL.host.
put 0755 "$warmup/caboose-gpu-warmup" usr/local/libexec/caboose-gpu/caboose-gpu-warmup
put 0755 "$warmup/caboose-gpu-warmup" "$host/lib/caboose-gpu-warmup"
put 0755 "$repo/guest/gpu/gfxstream/warmup/caboose-gpu-warmup-session" usr/local/libexec/caboose-gpu/caboose-gpu-warmup-session
# Libraries are installed executable, as the loader and Flatpak expect of shared objects.
find "$out" -name '*.so' -exec chmod 0755 {} +
python3 -I "$repo/guest/release/check_gpu_stack.py" "$out"
