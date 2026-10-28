#!/bin/bash
# Caboose plumbing for a container; independent of either display protocol.
set -euo pipefail
uid=$(id -u caboose)
runtime=/run/user/$uid
install -d -o caboose -g caboose -m 0700 "$runtime"
runuser -u caboose -- mkdir -p /home/caboose/.cache
install -d -m 0755 /run/caboose
file_pid=/run/caboose/files.pid
is_file_service() {
  [[ "$1" =~ ^[0-9]+$ ]] && [ -r "/proc/$1/cmdline" ] && tr '\0' '\n' < "/proc/$1/cmdline" | grep -Fxq /opt/caboose/files/caboose-files.py
}
if [ -s "$file_pid" ]; then
  pid=$(cat "$file_pid")
  if is_file_service "$pid"; then
    if [ "${1:-}" = restart ]; then
      start-stop-daemon --stop --signal TERM --pidfile "$file_pid"
      for _ in $(seq 1 10); do
        [ ! -r "/proc/$pid/stat" ] && break
        [ "$(awk '{print $3}' "/proc/$pid/stat")" = Z ] && break
        sleep 1
      done
      if [ -r "/proc/$pid/stat" ] && [ "$(awk '{print $3}' "/proc/$pid/stat")" != Z ]; then
        echo 'The previous Caboose file service did not stop.' >&2; exit 1
      fi
      rm -f "$file_pid"
    fi
  else
    rm -f "$file_pid"
  fi
fi
start-stop-daemon --start --oknodo --background --make-pidfile --pidfile "$file_pid" \
  --chuid caboose:caboose --exec /usr/bin/python3 -- /opt/caboose/files/caboose-files.py
for _ in $(seq 1 60); do ss -lnt | grep -Eq ':14700[[:space:]]' && break; sleep 1; done
ss -lnt | grep -Eq ':14700[[:space:]]' || { echo 'File service did not become ready' >&2; exit 1; }
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
