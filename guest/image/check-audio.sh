#!/usr/bin/env bash
# Check a running guest's sound without restarting it or playing anything: the owner's
# display runs its own PulseAudio, which its apps reach through PULSE_SERVER in their launch
# environment, and the agent seat has none.
set -euo pipefail
systemctl is-active --quiet caboose-display.service
runuser -u caboose -- sh -c 'set -a; . /run/caboose/display.env; test -n "${PULSE_SERVER:-}" && pactl info >/dev/null' ||
  { echo "The owner's display has no sound server" >&2; exit 1; }
if [ -s /run/caboose/agent-display.env ]; then
  runuser -u caboose -- sh -c 'set -a; . /run/caboose/agent-display.env; test -z "${PULSE_SERVER:-}"' ||
    { echo 'The agent seat must not play into the owner sound server' >&2; exit 1; }
fi
echo 'Audio checks passed'
