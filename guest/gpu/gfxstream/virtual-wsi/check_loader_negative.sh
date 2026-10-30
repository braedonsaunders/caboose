#!/bin/sh
set -eu
# The caller supplies only read-only /slice, /icd and retained include/sysroot mounts.
printf '%s  %s\n' 8ac1f100a2ce243be98962488b48051949f240271cba141f45f48d3d95b706ff /icd/libvulkan_gfxstream.so | sha256sum -c -
sha256sum /icd/libvulkan_gfxstream.so /usr/lib/x86_64-linux-gnu/libvulkan.so.1 /slice/loader_negative.c /slice/check_loader_negative.sh
task_root=$(mktemp -d /tmp/caboose-loader-check-XXXXXX)
trap 'rm -f "$task_root/check" "$task_root/icd.json"; rmdir "$task_root/home" "$task_root/runtime" "$task_root"' EXIT
mkdir "$task_root/home" "$task_root/runtime"
chmod 700 "$task_root/runtime"
cat > "$task_root/icd.json" <<'EOF'
{"file_format_version":"1.0.0","ICD":{"library_path":"/icd/libvulkan_gfxstream.so","api_version":"1.1.0"}}
EOF
timeout 30 cc -std=c11 -D_POSIX_C_SOURCE=200809L -Wall -Wextra -Werror \
    -I/work/mesa-private/include /slice/loader_negative.c -ldl -o "$task_root/check"
timeout 15 env -i PATH=/usr/bin:/bin LD_LIBRARY_PATH=/work/sysroot/lib \
    HOME="$task_root/home" XDG_RUNTIME_DIR="$task_root/runtime" \
    VK_DRIVER_FILES="$task_root/icd.json" VK_ICD_FILENAMES="$task_root/icd.json" \
    CABOOSE_GFXSTREAM_SOCKET="$task_root/runtime/nonexistent-broker.sock" \
    CABOOSE_GFXSTREAM_SURFACE_SOCKET="$task_root/runtime/nonexistent-surface.sock" \
    "$task_root/check" /usr/lib/x86_64-linux-gnu/libvulkan.so.1
