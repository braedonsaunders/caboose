#!/bin/bash
# Caboose plumbing for a container: the file and terminal services, updating the owner's
# notification endpoint, and printing.
set -euo pipefail
uid=$(id -u caboose)
runtime=/run/user/$uid
install -d -o caboose -g caboose -m 0700 "$runtime"
runuser -u caboose -- mkdir -p /home/caboose/.cache
install -d -m 0755 /run/caboose
# Inspect owner processes as that owner: container root may lack ptrace permission and
# see an empty cmdline for another uid. Discovering the exact script also repairs stale
# pid files left by an earlier failed restart. Never adopt a different program on the port.
owner_service_pid() {
  runuser -u caboose -- /usr/bin/python3 - "$1" <<'PYTHON'
import os, pathlib, sys
matches = []
for proc in pathlib.Path('/proc').iterdir():
    if not proc.name.isdigit(): continue
    try:
        if proc.stat().st_uid != os.getuid(): continue
        args = (proc / 'cmdline').read_bytes().split(b'\0')
        if len(args) > 1 and args[1] == os.fsencode(sys.argv[1]) and pathlib.Path(os.fsdecode(args[0])).name.startswith('python'):
            matches.append(proc.name)
    except (OSError, ValueError): pass
if len(matches) > 1:
    sys.exit('Multiple processes run the same Caboose service; refusing to replace them.')
print(matches[0] if matches else '')
PYTHON
}

owner_service_ready() {
  runuser -u caboose -- /usr/bin/python3 - "$1" "$2" <<'PYTHON'
import os, pathlib, sys
pid, port = sys.argv[1], int(sys.argv[2])
inodes = set()
for table in ('/proc/net/tcp', '/proc/net/tcp6'):
    for line in pathlib.Path(table).read_text().splitlines()[1:]:
        fields = line.split()
        if int(fields[1].split(':')[1], 16) == port and fields[3] == '0A':
            inodes.add('socket:[' + fields[9] + ']')
try:
    ready = any(os.readlink(fd) in inodes for fd in pathlib.Path('/proc', pid, 'fd').iterdir())
except OSError:
    ready = False
sys.exit(0 if ready else 1)
PYTHON
}

owner_service() {
  local script=$2 port=$3 label=$4 pidfile=/run/caboose/$1.pid pid
  pid=$(owner_service_pid "$script")
  if [ -n "$pid" ]; then
    printf '%s\n' "$pid" > "$pidfile"
    if [ "${MODE:-}" = restart ]; then
      start-stop-daemon --stop --signal TERM --pidfile "$pidfile"
      for _ in $(seq 1 10); do
        [ ! -r "/proc/$pid/stat" ] && break
        [ "$(awk '{print $3}' "/proc/$pid/stat")" = Z ] && break
        sleep 1
      done
      if [ -r "/proc/$pid/stat" ] && [ "$(awk '{print $3}' "/proc/$pid/stat")" != Z ]; then
        echo "The previous $label did not stop." >&2; return 1
      fi
      pid=
    fi
  fi
  if [ -z "$pid" ]; then
    rm -f "$pidfile"
    start-stop-daemon --start --background --make-pidfile --pidfile "$pidfile" \
      --chuid caboose:caboose --exec /usr/bin/python3 -- "$script"
    for _ in $(seq 1 20); do
      [ -s "$pidfile" ] && break
      sleep 0.1
    done
    pid=$(cat "$pidfile")
  fi
  for _ in $(seq 1 60); do
    if [ ! -r "/proc/$pid/stat" ] || [ "$(awk '{print $3}' "/proc/$pid/stat")" = Z ]; then
      echo "$label exited before becoming ready" >&2; return 1
    fi
    owner_service_ready "$pid" "$port" && return 0
    sleep 1
  done
  echo "$label did not become ready" >&2; return 1
}
MODE=${1:-}
# The keyring needs both buses even when the owner display stays stopped.
install -d -m 0755 /run/dbus
# /run survives a container stop. Only a failed connection with a known stale-socket
# error permits removing the socket; a live pid or any other failure stops recovery.
if python3 - <<'SYSTEM_BUS'
import errno, os, pathlib, socket, stat
path = pathlib.Path('/run/dbus/system_bus_socket')
with socket.socket(socket.AF_UNIX) as connection:
    connection.settimeout(2)
    try:
        connection.connect(str(path))
    except OSError as error:
        if error.errno not in (errno.ENOENT, errno.ECONNREFUSED):
            raise SystemExit(2)
    else:
        raise SystemExit(0)
pidfile = pathlib.Path('/run/dbus/pid')
if pidfile.exists():
    value = pidfile.read_text().strip()
    if not value.isdecimal() or int(value) <= 1:
        raise SystemExit(2)
    try:
        os.kill(int(value), 0)
    except ProcessLookupError:
        pass
    else:
        raise SystemExit(2)
try:
    if not stat.S_ISSOCK(path.lstat().st_mode):
        raise SystemExit(2)
    path.unlink()
except FileNotFoundError:
    pass
pidfile.unlink(missing_ok=True)
raise SystemExit(1)
SYSTEM_BUS
then :; else
  status=$?
  [ "$status" = 1 ] || { echo 'System bus recovery requires operator attention' >&2; exit "$status"; }
  dbus-daemon --system --fork
fi
session_bus() {
  local bus=$1
  # /run survives a container stop. A socket file alone does not prove its daemon lives.
  if runuser -u caboose -- python3 - "$bus" <<'PY'
import errno, socket, sys
with socket.socket(socket.AF_UNIX) as connection:
    connection.settimeout(2)
    try:
        connection.connect(sys.argv[1])
    except OSError as error:
        sys.exit(1 if error.errno in (errno.ENOENT, errno.ECONNREFUSED) else 2)
PY
  then return; else
    local status=$?
    [ "$status" = 1 ] || return "$status"
  fi
  rm -f -- "$bus"
  runuser -u caboose -- dbus-daemon --session --address="unix:path=$bus" --fork
}

session_bus "$runtime/bus"
owner_service files /opt/caboose/files/caboose-files.py 14700 'Caboose file service'
owner_service terminal /opt/caboose/terminal/caboose-terminal.py 14701 'Caboose terminal service'
# The owner's notification endpoint (guest/notifications) runs with the owner's display
# (caboose-session) and records the owner's notifications itself; a separate monitor from
# older components is stopped. An update restarts a running endpoint so it loads the new code;
# the old one releases the D-Bus name before the new one asks for it.
owner_process() {
  local pidfile=$1 script=$2 pid
  [ -s "$pidfile" ] || return 1
  pid=$(cat "$pidfile")
  [[ "$pid" =~ ^[0-9]+$ ]] && [ -r "/proc/$pid/cmdline" ] && [ "$(stat -c %u "/proc/$pid")" = "$uid" ] &&
    [ "$(awk '{print $3}' "/proc/$pid/stat")" != Z ] && runuser -u caboose -- grep -zFxq "$script" "/proc/$pid/cmdline"
}
monitor_pid="$runtime/caboose-notifications.pid"
if owner_process "$monitor_pid" /opt/caboose/notifications/monitor.py; then runuser -u caboose -- kill -TERM "$(cat "$monitor_pid")" || true; fi
rm -f "$monitor_pid"
endpoint_pid="$runtime/caboose-notification-daemon.pid"
if [ "$MODE" = restart ] && owner_process "$endpoint_pid" /opt/caboose/notifications/daemon.py; then
  runuser -u caboose -- kill -TERM "$(cat "$endpoint_pid")" || true
  for _ in $(seq 1 50); do owner_process "$endpoint_pid" /opt/caboose/notifications/daemon.py || break; sleep 0.1; done
  if owner_process "$endpoint_pid" /opt/caboose/notifications/daemon.py; then
    echo 'The previous notification endpoint did not stop.' >&2; exit 1
  fi
  runuser -u caboose -- touch /home/caboose/.cache/caboose-notification-daemon.log
  runuser -u caboose -- env HOME=/home/caboose XDG_RUNTIME_DIR="$runtime" DBUS_SESSION_BUS_ADDRESS="unix:path=$runtime/bus" \
    /bin/sh -c 'echo $$ > "$0"; exec python3 /opt/caboose/notifications/daemon.py --owner' "$endpoint_pid" \
    >>/home/caboose/.cache/caboose-notification-daemon.log 2>&1 < /dev/null &
fi
# The native bridge runs with the owner's display (caboose-session); an update restarts a
# running one so it loads the new code.
bridge_pid="$runtime/caboose-bridge.pid"
if [ "${1:-}" = restart ] && [ -s "$bridge_pid" ]; then
  pid=$(cat "$bridge_pid")
  if [[ "$pid" =~ ^[0-9]+$ ]] && [ -r "/proc/$pid/cmdline" ] && runuser -u caboose -- grep -zFxq /opt/caboose/bridge/caboose-bridge "/proc/$pid/cmdline"; then
    runuser -u caboose -- kill -TERM "$pid" || true
    rm -f "$bridge_pid"
    runuser -u caboose -- touch /home/caboose/.cache/caboose-bridge.log
    runuser -u caboose -- env HOME=/home/caboose XDG_RUNTIME_DIR="$runtime" DBUS_SESSION_BUS_ADDRESS="unix:path=$runtime/bus" \
      /bin/sh -c 'echo $$ > "$0"; exec /usr/bin/python3 /opt/caboose/bridge/caboose-bridge daemon' "$bridge_pid" \
      >>/home/caboose/.cache/caboose-bridge.log 2>&1 < /dev/null &
  fi
fi
if lpstat -r 2>/dev/null | grep -q 'scheduler is running'; then
  /usr/local/libexec/caboose-phone-printer-setup
fi
