#!/usr/bin/env bash
# Check a running guest's :100 audio without restarting it or playing sound.
set -euo pipefail
systemctl is-active --quiet caboose-xpra.service
pgrep -u caboose -x pulseaudio >/dev/null || { echo 'PulseAudio is not running as caboose' >&2; exit 1; }
gst-inspect-1.0 lamemp3enc >/dev/null
gst-inspect-1.0 pulsesrc >/dev/null
# A fresh interactive or login shell on :100 must discover Xpra's private
# server; it must not send the separate agent seat to the owner's speakers.
runuser -u caboose -- env -u PULSE_SERVER DISPLAY=:100 bash -c '. /etc/profile.d/caboose-audio.sh; test -n "${PULSE_SERVER:-}"; pactl info >/dev/null'
runuser -u caboose -- env -u PULSE_SERVER DISPLAY=:101 bash -c '. /etc/profile.d/caboose-audio.sh; test -z "${PULSE_SERVER:-}"'
info=$(runuser -u caboose -- env DISPLAY=:100 xpra info :100)
grep -Eq "^audio\\.encoders=.*'mp3'" <<< "$info" || { echo 'Xpra does not offer MP3' >&2; exit 1; }
printf '%s\n' "$info" | grep -E '^audio\.encoders=|^client\.[0-9]+\.audio\.(speaker\.(codec|state|bytes)|microphone\.state)|^client\.[0-9]+\.connection\.output\.count\.audio-data' || true
