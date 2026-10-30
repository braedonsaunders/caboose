#!/bin/bash
# The a11y check, inside the test container (see ../check-a11y.sh, which starts it).
# /src is guest/desktop-mcp. Prints PASS/FAIL per assertion; exits 1 if any failed.
set -uo pipefail
failures=0
pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s: %s\n' "$1" "$2"; failures=$((failures + 1)); }
check() { local name=$1; shift; if "$@"; then pass "$name"; else fail "$name" "${detail:-assertion failed}"; fi; detail=; }
detail=
# The helper as a root exec channel runs it: as caboose, with nothing in the environment
# but DISPLAY (these Xvfb displays need no authority; the Caboose Display section below
# passes each seat's full launch environment, as caboose-host and the agent runner do).
a11y() { local display=$1; shift; runuser -u caboose -- env -i DISPLAY="$display" /usr/bin/python3 /opt/caboose/a11y.py "$@"; }
# py EXPR: evaluate a Python expression over the JSON on stdin (as d).
py() { python3 -c "import json, sys; d = json.load(sys.stdin); r = ($1); print(r if not isinstance(r, bool) else ('yes' if r else 'no'))"; }
yes() { [[ $1 == yes ]]; }
wait_for() { local file=$1 line=$2; for _ in $(seq 1 50); do grep -qxF "$line" "$file" 2>/dev/null && return 0; sleep 0.1; done; return 1; }
id_of() { py "[e['id'] for e in d['elements'] if e['name'] == '$1' and '$2' in e['role']][0]"; }
as_user() { runuser -u caboose -- env -i HOME=/home/caboose PATH=/usr/bin:/bin "$@"; }
logs=/tmp/a11y-check
install -d -o caboose -g caboose "$logs"

echo '== install.sh: helper and accessibility switches, no per-agent registration'
home=/home/caboose
sh /src/install.sh && sh /src/install.sh  # twice: it must be idempotent
check 'helper installed' test -x /opt/caboose/a11y.py -a -x /opt/caboose/desktop-mcp.mjs
check 'chromium flags installed' grep -q force-renderer-accessibility /etc/chromium.d/caboose-accessibility
check 'toolkit-accessibility defaults on' bash -c '[[ $(runuser -u caboose -- env HOME=/home/caboose gsettings get org.gnome.desktop.interface toolkit-accessibility) == true ]]'
check 'no agent config written' bash -c "[[ ! -e $home/.claude.json && ! -e $home/.codex ]]"
check 'vscode argv.json' grep -q '"force-renderer-accessibility": true' "$home/.vscode/argv.json"
check 'configs owned by caboose' bash -c "[[ -z \$(find $home/.vscode ! -uid 1000) ]]"

echo '== Xvfb :100 and :101 sharing one session bus and one accessibility registry'
for d in 100 101; do Xvfb ":$d" -screen 0 1280x800x24 -nolisten tcp >"$logs/xvfb$d.log" 2>&1 & done
install -d -o caboose -g caboose -m 0700 /run/user/1000
runuser -u caboose -- dbus-daemon --session --address=unix:path=/run/user/1000/bus --fork >/dev/null
sleep 1
shared() { as_user DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus DISPLAY="$1" "${@:2}"; }
printf 'OWNER-SECRET-TEXT in the owner document\n' > "$home/owner.txt"; chown caboose "$home/owner.txt"
shared :100 mousepad "$home/owner.txt" >"$logs/mousepad.log" 2>&1 &
shared :100 python3 /src/check/fixture.py --title 'Owner window' --log "$logs/owner.log" --dialog >/dev/null 2>&1 &
shared :101 python3 /src/check/fixture.py --title 'Agent window' --log "$logs/agent.log" --dialog >/dev/null 2>&1 &
wait_for "$logs/owner.log" ready; wait_for "$logs/agent.log" ready; sleep 2
agent_pid=$(pgrep -u caboose -f 'title Agent window' | tail -1)
owner_pid=$(pgrep -u caboose -f 'title Owner window' | tail -1)
DISPLAY=:101 xdotool windowfocus "$(DISPLAY=:101 xdotool search --name 'Save changes' | head -1)"; sleep 0.5

elements=$(a11y :101 elements --display :101)
echo "$elements" | head -c 600; echo
check 'elements: focused window is the dialog' yes "$(echo "$elements" | py "d['window']['title'] == 'Save changes?'")"
check 'elements: Save, Cancel, entry and check box with bounds' yes "$(echo "$elements" | py "{(e['role'], e['name']) for e in d['elements'] if e['bounds']['width'] > 0 and e['bounds']['height'] > 0} >= {('button', 'Save'), ('button', 'Cancel'), ('text', 'File name'), ('check box', 'Keep a backup')}")"
found=$(a11y :101 find --display :101 --query save --role button)
check 'find: Save button, only the agent'"'"'s' yes "$(echo "$found" | py "[(e['name'], e['id'].split('-')[1]) for e in d['elements']] == [('Save', '$agent_pid')]")"
save=$(echo "$found" | py "d['elements'][0]['id']")
check 'act press: Save clicked' bash -c "[[ \$(runuser -u caboose -- env -i DISPLAY=:101 /usr/bin/python3 /opt/caboose/a11y.py act --display :101 --element '$save' --action press) == '{\"ok\": true}' ]]"
check 'act press: observable' wait_for "$logs/agent.log" 'clicked Save'
entry=$(echo "$elements" | id_of 'File name' text)
a11y :101 act --display :101 --element "$entry" --action set-text --text 'agent wrote this' >/dev/null
check 'act set-text: entry written' wait_for "$logs/agent.log" 'text agent wrote this'
a11y :101 act --display :101 --element "$entry" --action set-text --text '-5 starts with a dash' >/dev/null
check 'act set-text: a value starting with a dash, passed as caboose-host does' wait_for "$logs/agent.log" 'text -5 starts with a dash'
a11y :101 act --display :101 --element "$entry" --action set-text --text 'agent wrote this' >/dev/null
check 'act focus' bash -c "runuser -u caboose -- env -i DISPLAY=:101 /usr/bin/python3 /opt/caboose/a11y.py act --display :101 --element '$entry' --action focus | grep -q true"
a11y :101 act --display :101 --element "$(echo "$elements" | id_of 'Keep a backup' 'check box')" --action press >/dev/null
check 'act press: check box toggled' wait_for "$logs/agent.log" 'toggled True'
text=$(a11y :101 text --display :101)
check 'text: label and entry contents' yes "$(echo "$text" | py "'Save your changes to report.txt before closing?' in d['text'] and 'agent wrote this' in d['text']")"

# Starting the display's own bus now (as the computer does at display start) publishes
# AT_SPI_BUS; the apps already running stay on the shared bus and are still found.
check 'bus started for the display' yes "$(a11y :101 bus --display :101 | py "d['source'] == 'display session bus'")"
check 'apps on an earlier bus still found' yes "$(a11y :101 find --display :101 --query save --role button | py "[e['name'] for e in d['elements']] == ['Save']")"

echo '== isolation: nothing from :100 reaches :101'
owner_elements=$(a11y :100 elements --display :100)
owner_save=$(a11y :100 find --display :100 --query save --role button | py "d['elements'][0]['id'] if d['elements'] else ''")
check 'owner display read on its own' yes "$(a11y :100 text --display :100 | py "'OWNER' in d['text'] or 'Save your changes' in d['text']")"
check ':101 lists no owner pid' yes "$(echo "$elements" | py "all(e['id'].split('-')[1] == '$agent_pid' for e in d['elements'])")"
check ':101 finds no owner window' yes "$(a11y :101 find --display :101 --query owner | py "d['elements'] == []")"
check ':101 text has no owner text' yes "$(a11y :101 text --display :101 | py "'OWNER-SECRET-TEXT' not in d['text']")"
a11y :101 act --display :101 --element "$owner_save" --action press >"$logs/cross.json"; cross=$?
check 'owner element id rejected on :101 (exit 3)' bash -c "[[ $cross == 3 && \$(cat $logs/cross.json) == '{\"ok\": false, \"error\": \"element not found\"}' ]]"
check 'owner window untouched' bash -c "! grep -q 'clicked Save' $logs/owner.log"
shared :101 python3 /src/check/fixture.py --title 'Straddler' --log "$logs/straddler.log" --also-display :100 >/dev/null 2>&1 &
wait_for "$logs/straddler.log" ready
# "ready" is logged before GTK flushes its windows; wait for the one on :100 to exist.
for _ in $(seq 1 40); do as_user DISPLAY=:100 xdotool search --name '^Straddler elsewhere$' >/dev/null 2>&1 && break; sleep 0.25; done
for _ in $(seq 1 20); do
  DISPLAY=:101 xdotool windowfocus "$(DISPLAY=:101 xdotool search --name '^Straddler$' | head -1)" 2>/dev/null; sleep 0.3
  straddler=$(a11y :101 elements --display :101)
  [[ $(echo "$straddler" | py "d['window']['title']") == Straddler ]] && break
done
detail=$straddler
check 'a process with windows on both displays is not read' yes "$(echo "$straddler" | py "d['window']['title'] == 'Straddler' and d['elements'] == [] and 'another display' in d['note']")"
kill "$(pgrep -u caboose -f 'title Straddler' | tail -1)" 2>/dev/null

echo '== stale ids'
a11y :101 act --display :101 --element "${save%-*}-000000" --action press >/dev/null; code=$?
check 'tampered fingerprint rejected (exit 3)' test "$code" = 3
a11y :101 act --display :101 --element "${save%%-*}-$agent_pid-9.9.9-${save##*-}" --action press >/dev/null; code=$?
check 'unknown path rejected (exit 3)' test "$code" = 3
a11y :101 act --display :101 --element 'not-an-id' --action press >/dev/null; code=$?
check 'malformed id rejected (exit 3)' test "$code" = 3
kill "$agent_pid"; sleep 0.5
shared :101 python3 /src/check/fixture.py --title 'Agent window' --log "$logs/agent2.log" --dialog >/dev/null 2>&1 &
wait_for "$logs/agent2.log" ready; sleep 1
a11y :101 act --display :101 --element "$save" --action press >/dev/null; code=$?
check 'id from a closed window rejected (exit 3)' test "$code" = 3
check 'replacement window untouched' bash -c "! grep -q 'clicked Save' $logs/agent2.log"
pkill -u caboose -f fixture.py; pkill -u caboose mousepad; pkill Xvfb; sleep 1

echo '== Caboose Display: the owner display and the agent seat, as the computer runs them'
# The flags that bear on this check; the rest (token, encoder, sound) do not. Each instance
# writes its launch environment once it is ready, as the computer's units do.
install -d -o caboose -g caboose -m 0700 /run/user/1000
# Session buses of their own, as on the computer (the X checks above used the user bus).
for bus in owner-bus agent-bus; do
  [ -S "/run/user/1000/$bus" ] || runuser -u caboose -- dbus-daemon --session --address="unix:path=/run/user/1000/$bus" --fork >/dev/null
done
display() {  # display NAME BUS ARGS...
  local name=$1 bus=$2; shift 2
  as_user XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/1000/$bus" \
    CABOOSE_VIDEO_SOCKET="/run/user/1000/caboose-video-$name.sock" \
    /usr/local/bin/caboose-display --no-auth --no-audio --env-file "$logs/$name.env" "$@" >"$logs/$name.log" 2>&1 &
}
display owner owner-bus --listen 127.0.0.1:14600
display agent agent-bus --listen 127.0.0.1:14601 --socket wayland-caboose-agent --x-display 101
for name in owner agent; do for _ in $(seq 1 100); do [ -s "$logs/$name.env" ] && break; sleep 0.1; done; done
check 'both instances wrote their launch environment' bash -c "[ -s $logs/owner.env ] && [ -s $logs/agent.env ]"
check 'each instance names its own control socket' bash -c "grep -q 'CABOOSE_DISPLAY_CONTROL=.*/wayland-caboose-0/control.sock' $logs/owner.env && grep -q 'CABOOSE_DISPLAY_CONTROL=.*/wayland-caboose-agent/control.sock' $logs/agent.env"
check 'each instance has its own X authority' bash -c "[ \"\$(grep XAUTHORITY $logs/owner.env)\" != \"\$(grep XAUTHORITY $logs/agent.env)\" ]"
# As caboose-host and the agent runner run things: as caboose, with only the seat's launch
# environment (and its session bus).
on() {  # on owner|agent COMMAND...
  local name=$1 bus=owner-bus; shift; [ "$name" = agent ] && bus=agent-bus
  runuser -u caboose -- env -i HOME=/home/caboose PATH=/usr/bin:/bin:/usr/local/bin DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/1000/$bus" \
    /bin/sh -c 'set -a; . "$0"; set +a; exec "$@"' "$logs/$name.env" "$@"
}
seat() { on agent /usr/bin/python3 /opt/caboose/a11y.py "$@"; }
owner() { on owner /usr/bin/python3 /opt/caboose/a11y.py "$@"; }
windows() { on "$1" /usr/bin/python3 /opt/caboose/seat.py windows; }
owner bus --display :110 --wait 30 > "$logs/bus110.json"; seat bus --display :101 --wait 30 > "$logs/bus101.json"
check 'each seat uses its session bus for accessibility' bash -c "grep -q '\"source\": \"session bus\"' $logs/bus110.json && grep -q '\"source\": \"session bus\"' $logs/bus101.json"
check 'each seat has its own accessibility bus' bash -c "[[ \$(python3 -c 'import json; print(json.load(open(\"$logs/bus110.json\"))[\"address\"] != json.load(open(\"$logs/bus101.json\"))[\"address\"])') == True ]]"
check 'AT_SPI_BUS on each Xwayland is its seat bus' bash -c "for n in owner agent; do d=\$(runuser -u caboose -- env -i sh -c 'set -a; . \"\$0\"; xprop -root AT_SPI_BUS' $logs/\$n.env); [ \$n = owner ] && b=$logs/bus110.json || b=$logs/bus101.json; grep -qF \"\$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[\"address\"])' \$b)\" <<< \"\$d\" || exit 1; done"

echo '== The owner display: a native Wayland app and an X11 app, as the screen routes read them'
on owner python3 /src/check/fixture.py --title 'Owner Wayland' --log "$logs/ow.log" --dialog >/dev/null 2>&1 &
wait_for "$logs/ow.log" ready; sleep 1
check 'the GTK app is a Wayland window' yes "$(windows owner | py "any(w['title'] == 'Save changes?' and w['x11'] is None for w in d['windows'])")"
oelements=$(owner elements --display :110)
check 'Wayland dialog: Save, Cancel, field and check box listed' yes "$(echo "$oelements" | py "{('button', 'Save'), ('button', 'Cancel'), ('text', 'File name'), ('check box', 'Keep a backup')} <= {(e['role'].replace('push ', ''), e['name']) for e in d['elements']}")"
check 'Wayland dialog: bounds lie inside the window' yes "$(windows owner | python3 -c "
import json, sys
win = [w for w in json.load(sys.stdin)['windows'] if w['title'] == 'Save changes?'][0]
x, y, w, h = win['rect']
els = json.loads(sys.argv[1])['elements']
print('yes' if els and all(x <= e['bounds']['x'] and e['bounds']['x'] + e['bounds']['width'] <= x + w and y <= e['bounds']['y'] and e['bounds']['y'] + e['bounds']['height'] <= y + h for e in els) else 'no')" "$oelements")"
owner act --display :110 --element "$(echo "$oelements" | id_of 'File name' text)" --action set-text --text 'owner wrote this' >/dev/null
check 'Wayland dialog: set-text' wait_for "$logs/ow.log" 'text owner wrote this'
owner act --display :110 --element "$(echo "$oelements" | id_of 'Keep a backup' 'check box')" --action press >/dev/null
check 'Wayland dialog: press toggles the check box' wait_for "$logs/ow.log" 'toggled True'
# The screen routes' typing and shortcuts go through the seat's keyboard to the focused window.
owner act --display :110 --element "$(echo "$oelements" | id_of 'File name' text)" --action focus >/dev/null
on owner python3 /opt/caboose/seat.py key -- ctrl+a BackSpace >/dev/null
on owner python3 /opt/caboose/seat.py type -- '-typed by the screen route' >/dev/null
check 'seat keys and typing reach the focused Wayland field' wait_for "$logs/ow.log" 'text -typed by the screen route'
owner act --display :110 --element "$(echo "$oelements" | id_of Save button)" --action press >/dev/null
check 'Wayland dialog: press Save' wait_for "$logs/ow.log" 'clicked Save'
pkill -u caboose -f 'title Owner Wayland'; sleep 0.5
on owner env GDK_BACKEND=x11 python3 /src/check/fixture.py --title 'Owner X11' --log "$logs/ox.log" --dialog >/dev/null 2>&1 &
wait_for "$logs/ox.log" ready; sleep 1
check 'the X11 app is an Xwayland window' yes "$(windows owner | py "any(w['title'] == 'Save changes?' and w['x11'] for w in d['windows'])")"
xsave=$(owner find --display :110 --query save --role button | py "d['elements'][0]['id'] if len(d['elements']) == 1 else ''")
check 'X11 dialog: Save found' test -n "$xsave"
owner act --display :110 --element "$xsave" --action press >/dev/null
check 'X11 dialog: press Save' wait_for "$logs/ox.log" 'clicked Save'
pkill -u caboose -f 'title Owner X11'; sleep 0.5

echo '== The agent seat with nobody watching: Wayland apps, kept apart from the owner'
on owner python3 /src/check/fixture.py --title 'Owner window' --log "$logs/cd-owner.log" --dialog >/dev/null 2>&1 &
on agent python3 /src/check/fixture.py --title 'Agent window' --log "$logs/cd-agent.log" --dialog >/dev/null 2>&1 &
wait_for "$logs/cd-owner.log" ready; wait_for "$logs/cd-agent.log" ready; sleep 2
asave=$(seat find --display :101 --query save --role button | py "d['elements'][0]['id'] if len(d['elements']) == 1 else ''")
check 'agent app found with nobody watching' test -n "$asave"
check 'agent seat lists no owner window' yes "$(seat find --display :101 --query owner | py "d['elements'] == []")"
osave=$(owner find --display :110 --query save --role button | py "d['elements'][0]['id']")
seat act --display :101 --element "$osave" --action press >"$logs/cd-cross.json"; cross=$?
check 'owner element id rejected on the agent seat (exit 3)' test "$cross" = 3
seat act --display :101 --element "$asave" --action press >/dev/null
check 'press on the agent seat' wait_for "$logs/cd-agent.log" 'clicked Save'
check 'owner window untouched' bash -c "! grep -q 'clicked Save' $logs/cd-owner.log"
pkill -u caboose -f 'title Agent window'; sleep 0.5

echo '== Coordinate tools on the agent seat with nobody watching'
mcp() {  # one tool call per server process, so calls run strictly in order
  printf '%s\n' \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"check","version":"0"}}}' \
    "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"$1\",\"arguments\":$2}}" |
    on agent env CABOOSE_AGENT_DISPLAY=:101 timeout 60 node /opt/caboose/desktop-mcp.mjs |
    python3 -c "import json, sys; [print(json.dumps(m)) for m in map(json.loads, sys.stdin) if m.get('id') == 2]"
}
on agent python3 /src/check/fixture.py --title 'Seat window' --log "$logs/seat.log" --dialog >/dev/null 2>&1 &
wait_for "$logs/seat.log" ready; sleep 1
check 'high-APM persistent MCP contract' on agent timeout 60 node /src/check/high-apm.mjs
check 'mcp list_windows shows the dialog' yes "$(mcp list_windows '{}' | py "any(w['title'] == 'Save changes?' for w in json.loads(d['result']['content'][0]['text']))")"
centre() {
  seat find --display :101 --query "$1" ${2:+--role "$2"} |
    python3 -c "import json, sys; b = json.load(sys.stdin)['elements'][0]['bounds']; print(b['x'] + b['width'] // 2, b['y'] + b['height'] // 2)"
}
read -r ex ey <<< "$(centre 'File name')"; read -r sx sy <<< "$(centre Save button)"
mcp click "{\"x\":$ex,\"y\":$ey}" >/dev/null
mcp key '{"combo":"ctrl+a"}' >/dev/null
mcp type '{"text":"typed-by-agent.txt"}' >/dev/null
check 'mcp click and type reach the field' wait_for "$logs/seat.log" 'text typed-by-agent.txt'
mcp click "{\"x\":$sx,\"y\":$sy}" >/dev/null
check 'mcp click presses Save' wait_for "$logs/seat.log" 'clicked Save'
on agent python3 /src/check/fixture.py --title 'Seat window' --log "$logs/seat2.log" --dialog >/dev/null 2>&1 &
wait_for "$logs/seat2.log" ready; sleep 1
mcp screenshot '{}' | python3 -c "import json, sys, base64; open('$logs/seat.png', 'wb').write(base64.b64decode(json.load(sys.stdin)['result']['content'][0]['data']))"
colours=$(convert "$logs/seat.png" -format %k info: 2>&1); echo "screenshot: $(identify "$logs/seat.png" 2>&1 | cut -d' ' -f2-3), $colours colours"
check 'mcp screenshot shows the new window, not a blank seat' test "${colours:-0}" -gt 16
pkill -u caboose -f 'title Seat window'; sleep 0.5

# Chromium reads /etc/chromium.d/caboose-accessibility; --no-sandbox only because this test
# container has no user namespaces for its sandbox. It runs as a native Wayland client.
on agent chromium --ozone-platform=wayland --no-sandbox --no-first-run --disable-gpu --user-data-dir="$logs/chromium" \
  --window-size=900,700 file:///src/check/page.html >"$logs/chromium.log" 2>&1 &
for _ in $(seq 1 60); do seat find --display :101 --query Subscribe | grep -q '"button"' && break; sleep 0.5; done
check 'chromium is a Wayland window' yes "$(windows agent | py "any('Chromium' in w['title'] and w['x11'] is None for w in d['windows'])")"
page=$(seat elements --display :101)
check 'chromium: link and button inside the page listed' yes "$(echo "$page" | py "{('link', 'Read the docs'), ('button', 'Subscribe'), ('entry', 'Email')} <= {(e['role'], e['name']) for e in d['elements']}")"
email=$(echo "$page" | id_of Email entry)
seat act --display :101 --element "$email" --action set-text --text 'first@example.com' >/dev/null
seat act --display :101 --element "$email" --action set-text --text 'me@example.com' >/dev/null  # replaces
seat act --display :101 --element "$(echo "$page" | id_of Subscribe button)" --action press >/dev/null
sleep 1
check 'chromium: set-text and press ran the page' yes "$(seat elements --display :101 | py "d['window']['title'].startswith('Subscribed me@example.com')")"
read -r lx ly <<< "$(centre 'Read the docs' link)"
mcp click "{\"x\":$lx,\"y\":$ly}" >/dev/null
sleep 1
check 'chromium: a click at the link'"'"'s bounds follows it' yes "$(seat text --display :101 | py "'PAGE-BODY-TEXT with Read the docs inside a sentence.' in d['text'] and 'page.html#docs' in d['text']")"

echo '== caboose-desktop-mcp over stdio, driving the page'
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"check","version":"0"}}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"find","arguments":{"query":"read the docs","role":"link"}}}' \
  '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"read_text","arguments":{}}}' |
  on agent env CABOOSE_AGENT_DISPLAY=:101 timeout 60 node /opt/caboose/desktop-mcp.mjs > "$logs/mcp.out"
# Preserve helper errors/stacks before JSON assertions consume the response text.
cat "$logs/mcp.out"
answer() { python3 -c "import json, sys; [print(m['result']['content'][0]['text']) for m in map(json.loads, open('$logs/mcp.out')) if m.get('id') == $1]"; }
check 'mcp find' yes "$(answer 2 | py "[(e['role'], e['name']) for e in d['elements']] == [('link', 'Read the docs')]")"
check 'mcp read_text' yes "$(answer 3 | py "'PAGE-BODY-TEXT' in d['text']")"
pkill -u caboose -f chromium; pkill -u caboose -f fixture.py
pkill -u caboose caboose-display

echo
if (( failures )); then echo "$failures assertion(s) failed"; exit 1; fi
echo 'All a11y checks passed'
