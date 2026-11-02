#!/bin/bash
# Run inside a started computer. Does not restart or park it.
set -euo pipefail
/usr/local/bin/caboose-session ready
# The compositor's PulseAudio, which applications on the owner's display play into.
runuser -u caboose -- sh -c 'set -a; . /run/caboose/display.env; pactl info' >/dev/null ||
  { echo "The owner's display has no sound server" >&2; exit 1; }
echo 'Display and audio checks passed'
