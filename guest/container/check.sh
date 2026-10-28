#!/bin/bash
# Run inside a started GPU computer. Does not restart or park it.
set -euo pipefail
/usr/local/bin/caboose-session ready-display
libs=
if [ "${CABOOSE_GPU:-none}" = wsl ]; then libs=/usr/lib/wsl/lib; fi
encoders=$(runuser -u caboose -- env LD_LIBRARY_PATH="$libs" caboose-display --list-encoders)
has_nvidia() { [ -x /usr/lib/wsl/lib/nvidia-smi ] && /usr/lib/wsl/lib/nvidia-smi --query-gpu=name --format=csv,noheader >/dev/null 2>&1; }
case ${CABOOSE_GPU:-none} in
  wsl) if has_nvidia; then grep -q '^hevc (hevc_nvenc)' <<< "$encoders" || { echo 'NVENC HEVC is unavailable' >&2; exit 1; }; fi ;;
  nvidia) grep -q '^hevc (hevc_nvenc)' <<< "$encoders" || { echo 'NVENC HEVC is unavailable' >&2; exit 1; } ;;
  dri|none) ;;
  *) echo 'Invalid CABOOSE_GPU' >&2; exit 1 ;;
esac
grep -q '^h264 ' <<< "$encoders" || { echo 'H.264 is unavailable' >&2; exit 1; }
# The compositor's PulseAudio, which applications on the owner's display play into.
runuser -u caboose -- sh -c 'set -a; . /run/caboose/display.env; pactl info' >/dev/null ||
  { echo "The owner's display has no sound server" >&2; exit 1; }
printf '%s\n' "$encoders"
echo 'GPU encoding and audio checks passed'
