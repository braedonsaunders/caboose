#!/bin/bash
# Caboose plumbing for a container: the file and terminal services, the notification monitor
# and printing.
set -euo pipefail
uid=$(id -u caboose)
runtime=/run/user/$uid
install -d -o caboose -g caboose -m 0700 "$runtime"
runuser -u caboose -- mkdir -p /home/caboose/.cache
install -d -m 0755 /run/caboose
# A service of the owner's, kept in a pid file; `restart` replaces a running one.
# Readiness is its port listening (state 0A), read from /proc: the image has no iproute2 for ss.
owner_service() {
  local name=$1 script=$2 port=$3 label=$4 pidfile=/run/caboose/$1.pid pid
  if [ -s "$pidfile" ]; then
    pid=$(cat "$pidfile")
    if [[ "$pid" =~ ^[0-9]+$ ]] && [ -r "/proc/$pid/cmdline" ] && tr '\0' '\n' < "/proc/$pid/cmdline" | grep -Fxq "$script"; then
      if [ "${MODE:-}" = restart ]; then
        start-stop-daemon --stop --signal TERM --pidfile "$pidfile"
        for _ in $(seq 1 10); do
          [ ! -r "/proc/$pid/stat" ] && break
          [ "$(awk '{print $3}' "/proc/$pid/stat")" = Z ] && break
          sleep 1
        done
        if [ -r "/proc/$pid/stat" ] && [ "$(awk '{print $3}' "/proc/$pid/stat")" != Z ]; then
          echo "The previous $label did not stop." >&2; exit 1
        fi
        rm -f "$pidfile"
      fi
    else
      rm -f "$pidfile"
    fi
  fi
  start-stop-daemon --start --oknodo --background --make-pidfile --pidfile "$pidfile" \
    --chuid caboose:caboose --exec /usr/bin/python3 -- "$script"
  local hex
  hex=$(printf '%04X' "$port")
  for _ in $(seq 1 60); do
    grep -Eq "^ *[0-9]+: [0-9A-F]+:$hex [0-9A-F]+:[0-9A-F]+ 0A " /proc/net/tcp /proc/net/tcp6 2>/dev/null && return 0
    sleep 1
  done
  echo "$label did not become ready" >&2; exit 1
}
MODE=${1:-}
owner_service files /opt/caboose/files/caboose-files.py 14700 'Caboose file service'
owner_service terminal /opt/caboose/terminal/caboose-terminal.py 14701 'Caboose terminal service'
monitor_pid="$runtime/caboose-notifications.pid"
monitor_running=false
if [ -s "$monitor_pid" ]; then
  pid=$(cat "$monitor_pid")
  if [[ "$pid" =~ ^[0-9]+$ ]] && [ -r "/proc/$pid/cmdline" ] && [ "$(stat -c %u "/proc/$pid")" = "$uid" ] && tr '\0' '\n' < "/proc/$pid/cmdline" | grep -Fxq /opt/caboose/notifications/monitor.py; then monitor_running=true; fi
fi
if $monitor_running && [ "${1:-}" = restart ]; then
  runuser -u caboose -- kill -TERM "$pid"
  rm -f "$monitor_pid"
  monitor_running=false
fi
if ! $monitor_running; then
  runuser -u caboose -- touch /home/caboose/.cache/caboose-notifications.log
  runuser -u caboose -- env HOME=/home/caboose XDG_RUNTIME_DIR="$runtime" DBUS_SESSION_BUS_ADDRESS="unix:path=$runtime/bus" \
    /bin/sh -c 'echo $$ > "$XDG_RUNTIME_DIR/caboose-notifications.pid"; exec /usr/bin/python3 /opt/caboose/notifications/monitor.py' \
    >>/home/caboose/.cache/caboose-notifications.log 2>&1 < /dev/null &
  sleep 1
  if [ ! -s "$monitor_pid" ] || ! runuser -u caboose -- kill -0 "$(cat "$monitor_pid")" 2>/dev/null; then
    echo 'The notification monitor did not start.' >&2; exit 1
  fi
fi
if ! lpstat -r 2>/dev/null | grep -q 'scheduler is running'; then /usr/sbin/cupsd; fi
/usr/local/libexec/caboose-phone-printer-setup
