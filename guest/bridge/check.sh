#!/bin/bash
# Run as root inside a running Caboose computer with the owner's display up and the bridge
# installed (guest/components). Plays the host's part itself; needs no phone.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
python3 -B "$here/selftest.py"
runuser -u caboose -- env HOME=/home/caboose XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \
  python3 -B "$here/check.py"
if [ -f /etc/geolocation ]; then echo 'note  /etc/geolocation exists: a phone is sharing its location'; fi
grep -qs '^enable=true' /etc/geoclue/conf.d/90-caboose.conf && echo 'ok    GeoClue static source enabled' || { echo 'FAIL  GeoClue static source is not configured' >&2; exit 1; }
