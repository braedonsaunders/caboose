# Sourced inside the computer before a task's setup, verify or reset, as the agent user with
# the agent seat's environment (/run/caboose/agent-display.env). BENCH is the run directory.
# The run's own home and data directories: no session restore or recent files carry over
# from the agent profile or an earlier task. The run directory is the agent profile of the
# desktop server too (CABOOSE_AGENT_PROFILE=$BENCH in --mcp), so applications the agent
# launches share this home. Settings stay with the seat's settings services (dconf, xfconf),
# which tasks reset themselves.
export HOME="$BENCH/home" XDG_CONFIG_HOME="$BENCH/home/.config" XDG_DATA_HOME="$BENCH/home/.local/share" \
  XDG_CACHE_HOME="$BENCH/home/.cache" XDG_STATE_HOME="$BENCH/home/.local/state"
(umask 077; mkdir -p "$HOME/.config" "$HOME/.local/share" "$HOME/.local/state" "$HOME/.cache")
TOOLS=${TOOLS:-/opt/caboose}  # where desktop MCP's helpers are installed
SEAT=$TOOLS/seat.py
# Start an application on the agent seat as desktop MCP's launch does, after announcing the
# assistive technology on the seat's accessibility bus as it does.
start() {
  gdbus call --session --dest org.a11y.Bus --object-path /org/a11y/bus --method org.freedesktop.DBus.Properties.Set \
    org.a11y.Status ScreenReaderEnabled '<true>' >/dev/null 2>&1
  ACCESSIBILITY_ENABLED=1 GNOME_ACCESSIBILITY=1 QT_LINUX_ACCESSIBILITY_ALWAYS_ON=1 XDG_SESSION_TYPE=wayland \
    setsid python3 "$TOOLS/launcher.py" "$(python3 -c 'import shlex, sys; print(shlex.join(sys.argv[1:]))' "$@")" >>"$BENCH/app.log" 2>&1 < /dev/null &
}
# A form page whose submit sets the title to COMPLETE only when the expected values are in.
page() {
  mkdir -p "$(dirname "$1")"
  cat > "$1" <<HTML
<!doctype html><html><head><title>$2</title></head><body><h1>$2</h1>
<form onsubmit="event.preventDefault(); document.title = (r.value === 'Iris Moss' && c.value === 'Granite Falls' && g.checked) ? '$3' : 'Incomplete';">
<p><label for="r">Recipient</label> <input id="r"></p><p><label for="c">City</label> <input id="c"></p>
<p><label><input type="checkbox" id="g"> Gift wrap</label></p>
<button type="button">Reset</button> <button type="submit">Ship order</button></form></body></html>
HTML
}
windows() { python3 "$SEAT" windows; }
window_title() { windows | python3 -c 'import json, sys; sys.exit(0 if any(w.get("title") == sys.argv[1] for w in json.load(sys.stdin)["windows"]) else 1)' "$1"; }
# Wait until a window of APP is on the seat and focused.
wait_window() {
  for _ in $(seq 1 600); do
    windows | python3 -c 'import json, sys; sys.exit(0 if any((w.get("app_id") or "").lower() == sys.argv[1].lower() and w.get("focused") and w.get("title") for w in json.load(sys.stdin)["windows"]) else 1)' "$1" && return 0
    sleep 0.1
  done
  windows; return 1
}
# The agent profile's LibreOffice profile, emptied between tasks: its document recovery would
# carry one task's unsaved documents into the next.
fresh_office() { rm -rf "${XDG_CONFIG_HOME:-$HOME/.config}/libreoffice"; }
# End every process on the agent seat's windows, and anything still running from this run.
end_apps() {
  for pid in $(windows | python3 -c 'import json, sys; print(" ".join({str(w["pid"]) for w in json.load(sys.stdin)["windows"] if w.get("pid")}))'); do kill "$pid" 2>/dev/null; done
  pkill -u "$(id -u)" -f -- "$BENCH" 2>/dev/null
  for _ in $(seq 1 50); do [ "$(windows | python3 -c 'import json, sys; print(len(json.load(sys.stdin)["windows"]))')" = 0 ] && break; sleep 0.1; done
  pkill -KILL -u "$(id -u)" -f -- "$BENCH" 2>/dev/null; true
}
