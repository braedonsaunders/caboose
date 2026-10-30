#!/bin/bash
# Exercise the real D-Bus endpoints without a VM or an APNs account.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
docker run --rm -v "$root/guest/notifications:/fixture:ro" debian:trixie-slim /bin/bash -euc '
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends dbus dbus-x11 python3 python3-gi libnotify-bin >/dev/null
  useradd -m -u 1000 caboose
  runuser -u caboose -- dbus-run-session -- /bin/bash -euc '\''
    python3 /fixture/daemon.py --owner >/tmp/service.log 2>&1 &
    service=$!
    trap "kill $service 2>/dev/null || true; wait $service 2>/dev/null || true" EXIT
    sleep 1
    python3 /fixture/check-respond.py
    dbus-run-session -- /fixture/check-agent-bus.sh
    sleep 1
    cat /tmp/service.log
    if grep -Fq agent-check /home/caboose/.cache/caboose/notifications/*.json; then echo "agent notification leaked" >&2; exit 1; fi
    echo "Owner notifications recorded and answered; agent notification excluded."
  '\''
'
