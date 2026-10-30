#!/bin/bash
# Run as root inside a running Caboose guest with the owner display and session bus up.
set -euo pipefail
runuser -u caboose -- env HOME=/home/caboose XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \
  /usr/bin/python3 "$(cd "$(dirname "$0")" && pwd)/check-respond.py" ||
  { echo 'Check caboose-notification-daemon.service and the owner session bus.' >&2; exit 1; }
