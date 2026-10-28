#!/bin/bash
# Run as root inside a running Caboose guest with the owner display and session bus up.
set -euo pipefail
marker="caboose-notification-check-$$-$(date +%s)"
dir=/home/caboose/.cache/caboose/notifications
runuser -u caboose -- env HOME=/home/caboose XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus DISPLAY=:100 notify-send "$marker" 'Owner notification check' || true
for _ in $(seq 1 20); do
  for f in "$dir"/*.json; do
    [ -f "$f" ] || continue
    if grep -Fq "$marker" "$f"; then
      echo 'Owner desktop notification reached the private queue.'
      rm -f "$f"
      exit 0
    fi
  done
  sleep 0.5
done
echo 'Notification did not reach the queue; check caboose-notifications service and session bus.' >&2
exit 1
