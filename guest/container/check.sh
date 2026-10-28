#!/bin/bash
# Run inside a started GPU computer. Does not restart or park it.
set -euo pipefail
/usr/local/bin/caboose-session ready :100
info=$(runuser -u caboose -- env HOME=/home/caboose XDG_RUNTIME_DIR=/run/user/1000 DISPLAY=:100 xpra info :100)
case ${CABOOSE_GPU:-none} in
  wsl) if [ -x /usr/lib/wsl/lib/nvidia-smi ] && /usr/lib/wsl/lib/nvidia-smi --query-gpu=name --format=csv,noheader >/dev/null 2>&1; then
    grep -q '^video.encoding.BGRX_to_h265=.*nvenc' <<< "$info" || { echo 'NVENC HEVC is unavailable' >&2; exit 1; }
    else grep -q '^encodings.core=.*h264' <<< "$info" || { echo 'H.264 is unavailable' >&2; exit 1; }; fi ;;
  nvidia) grep -q '^video.encoding.BGRX_to_h265=.*nvenc' <<< "$info" || { echo 'NVENC HEVC is unavailable' >&2; exit 1; } ;;
  dri|none) grep -q '^encodings.core=.*h264' <<< "$info" || { echo 'H.264 is unavailable' >&2; exit 1; } ;;
  *) echo 'Invalid CABOOSE_GPU' >&2; exit 1 ;;
esac
grep -Eq "^audio\.encoders=.*'mp3'" <<< "$info" || { echo 'Xpra does not offer MP3 audio' >&2; exit 1; }
gst-inspect-1.0 lamemp3enc >/dev/null
gst-inspect-1.0 pulsesrc >/dev/null
printf '%s\n' "$info" | grep -E '^encoding.nvenc.version=|^video.encoding.BGRX_to_h265=|^audio.encoders='
echo 'GPU encoding and audio checks passed'
