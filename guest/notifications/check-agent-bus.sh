#!/bin/bash
set -euo pipefail
python3 /fixture/daemon.py >/tmp/agent-notifications.log 2>&1 &
service=$!
trap 'kill "$service" 2>/dev/null || true; wait "$service" 2>/dev/null || true' EXIT
sleep 1
DISPLAY=:101 notify-send --app-name=agent agent-check text
