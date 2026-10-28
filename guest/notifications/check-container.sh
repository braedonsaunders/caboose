#!/bin/bash
# Exercise the real D-Bus monitor without a VM or an APNs account.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
docker run --rm -v "$root/guest/notifications:/fixture:ro" debian:trixie-slim /bin/bash -euc '
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends dbus dbus-x11 python3 python3-gi libnotify-bin >/dev/null
  useradd -m -u 1000 caboose
  runuser -u caboose -- dbus-run-session -- /bin/bash -euc '\''
    python3 /fixture/daemon.py >/tmp/service.log 2>&1 &
    service=$!
    python3 /fixture/monitor.py >/tmp/monitor.log 2>&1 &
    monitor=$!
    trap "kill $monitor $service 2>/dev/null || true; wait $monitor $service 2>/dev/null || true" EXIT
    sleep 1
    DISPLAY=:100 notify-send --app-name=owner owner-check text || true
    dbus-run-session -- /fixture/check-agent-bus.sh
    sleep 2
    cat /tmp/monitor.log
    grep -Fq owner-check /home/caboose/.cache/caboose/notifications/*.json
    if grep -Fq agent-check /home/caboose/.cache/caboose/notifications/*.json; then echo "agent notification leaked" >&2; exit 1; fi
    echo "Owner notification captured; agent notification excluded."
  '\''
'
