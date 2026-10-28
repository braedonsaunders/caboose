# caboose-desktop-mcp

An MCP server (stdio, newline-delimited JSON-RPC 2.0) that lets an agent see and drive GUI
apps on the agent seat without touching the owner's display. The agent seat is its own
Caboose Display instance whose apps run on Xwayland `:101`. Beside the server, `a11y.py`
reads and acts on a display's accessibility tree; the desktop tools use it on the agent seat,
and caboose-host's `/v1/screen` routes use it on the owner's display (Xwayland `:110`).

Both work on X11 windows. On the owner's display, apps prefer Wayland, and native Wayland
windows are not exposed to `a11y.py` or the screen routes. The agent seat runs its apps on
Xwayland alone, so every window there is reachable.

## Tools

The accessibility tools come first in the tool list, and their descriptions tell the model
to prefer them: they answer quickly, need no screenshot and no image tokens, and act on a
control by id rather than by guessed coordinates.

| Tool | Arguments | Does |
| --- | --- | --- |
| `elements` | — | the focused window's controls: `{ window: { title, app }, elements: [{ id, role, name, states, bounds }] }` |
| `find` | `query`, `role?` | elements whose name contains `query` (case-insensitive), optionally of one role |
| `click_element` | `id` | press it: its AT-SPI action, else a click at its centre |
| `set_text` | `id`, `text` | replace an editable element's text |
| `read_text` | — | the focused window's readable text, page text included |
| `screenshot` | `window?` | PNG of the display or one window |
| `list_windows`, `focus` | `window` | windows with geometry; raise one |
| `click`, `drag`, `type`, `key`, `scroll` | coordinates, text, keys | pointer and keyboard by coordinates (xdotool) |
| `launch` | `command` | start an app on the agent seat with the accessibility environment below |

A failure comes back as a tool error with a sentence the model can act on; an id that no
longer resolves says to list the window again.

caboose-agentd passes the server to every agent in ACP `session/new` (and on resume and
load) as `caboose-desktop`, with the seat's X11 environment: `CABOOSE_AGENT_DISPLAY` (the
display, default `:101`), `XAUTHORITY`, `XDG_RUNTIME_DIR`, `DBUS_SESSION_BUS_ADDRESS` and the
toolkit backends from `/run/caboose/agent-display.env`. The agent runner answers the agent's
permission requests itself, so asking before acting needs nothing from this server.

`screenshot` without a window composites each viewable window at its position, bottom to
top, onto a dark background, because Xwayland runs rootless and its root window has no
picture of its own. The seat's windows are viewable whether or not anyone is watching it,
so every tool works with no client attached.

## `a11y.py`

Python 3 with the AT-SPI bindings from `python3-pyatspi`, and libX11 through ctypes. It runs
as user `caboose` and always prints one JSON object:

```sh
a11y.py elements --display :101
a11y.py find     --display :101 --query save [--role button]
a11y.py act      --display :101 --element ID --action press|focus|set-text [--text T]
a11y.py text     --display :101
a11y.py bus      --display :101 [--wait SECONDS]
```

- `elements`: `{ "window": { "title", "app" }, "elements": [{ "id", "role", "name", "states",
  "bounds": { "x", "y", "width", "height" } }] }`. The focused window's visible buttons,
  links, fields, check boxes, radio buttons, menus and menu items, tabs, combo boxes, sliders,
  named list, tree and table items, and headings, plus any menu it has open, at most 200, in
  tree (reading) order. Roles are AT-SPI's names (`button`, `entry`, `link`, `check box`,
  `page tab`, …); states are drawn from `focused`, `checked`, `pressed`, `selected`,
  `expanded`, `collapsed`, `editable`, `mixed`, `required`, `invalid`, `read-only`,
  `multi-line`, `visited` and `disabled`. Bounds are screen pixels on that display. An
  unnamed field takes the name of its label.
- `find`: the same shape, for every showing element of the focused window whose name
  contains the query. A role matches when it equals the given role or contains it as a word,
  so `--role button` matches `button`, `toggle button` and `radio button`.
- `act`: `{ "ok": true }`. `press` performs the element's own action (`click`, `press`,
  `activate`, `jump`, `toggle`, `open`); only an element with none is clicked at its centre
  with xdotool. `focus` uses `Component.grab_focus`. `set-text` uses `EditableText`; a field
  without it (Chromium's and Electron's) is focused through AT-SPI and typed into with
  `xdotool --window`, which sends the keys to that one X window. An unknown, stale or
  vanished id exits 3 with `{ "ok": false, "error": "element not found" }`.
- `text`: `{ "window": {...}, "text": "..." }`: labels, field contents and documents, with
  each embedded object (a link in a paragraph, a paragraph in a page) expanded where it sits;
  at most 20000 characters, with `"truncated": true` when cut.
- `bus`: `{ "address", "source" }`; see below.

When a list is empty for a reason (no window, a window whose application exposes no tree,
an application with windows on two displays), `note` says so, and the agent falls back to
`screenshot`. Other failures exit 1 with `{ "error": … }` (`{ "ok": false, … }` for `act`);
bad arguments exit 2. Walks are bounded (8000 nodes, depth 48, 8 seconds). Values that start
with a dash are accepted (`--text -5` or `--text=-5`).

**Element ids** look like `600007-1342-1.0.3.0.1-edc227`: the X window the element was
listed from, the application's pid, the child-index path from the application, and a hash of
the element's role and name. An id resolves only while that window is still on the display,
owned by that pid, and the element at that path still has that role and name, so a stale id
is rejected rather than pressing whatever now sits at that path. Treat ids as opaque.

### Which accessibility bus

Callers run the helper as `caboose` with the display's launch environment (`DISPLAY`,
`XAUTHORITY`): caboose-host from its root exec channel with
`runuser -u caboose -- env <owner launch environment> python3 /opt/caboose/a11y.py …`, the
MCP server with the seat's environment. The helper finds the bus itself, trying in order:

1. `AT_SPI_BUS_ADDRESS`, if the caller set it (then nothing else);
2. the `AT_SPI_BUS` property on the display's root window, which at-spi-bus-launcher sets
   when the session bus that started it knows the display; every toolkit (libatspi,
   atk-bridge, GTK 4, Qt, Chromium) reads it before its session bus, so it is what makes all
   apps on a display share one bus;
3. the a11y bus of a session bus started for that display: one recorded as
   `DBUS_SESSION_BUS_ADDRESS` on the root window, or D-Bus's X11 autolaunch bus for this
   user;
4. the a11y bus of `$DBUS_SESSION_BUS_ADDRESS`, then of `/run/user/<uid>/bus`.

libatspi binds one bus per process, so when the focused window's application is not on the
first bus found, the helper runs itself again against the next one.

`a11y.py bus --display :N --wait 30` makes step 2 hold. If the display has no `AT_SPI_BUS`,
it asks a session bus started for the display for its a11y bus, and failing that starts one
with `dbus-launch --exit-with-x11` (it ends with the X server), whose at-spi-bus-launcher
then publishes `AT_SPI_BUS`. The computer runs it as each display becomes ready, before any
app: `ExecStartPost=` in `caboose-display.service` and `caboose-display-agent.service`, and
`caboose-session ready` and `start-agent` in the container. So the owner's display and the
agent seat each get their own bus. It is safe to repeat.

### Display isolation

Displays can still share a bus and its registry (an app may have joined a session bus
before `AT_SPI_BUS` existed). So the helper keeps to applications on the requested display
by process:

- the focused window is `_NET_ACTIVE_WINDOW` on that display, else its X input focus, else the
  topmost mapped client;
- its application is the AT-SPI application whose pid is that window's `_NET_WM_PID`;
- that pid must own no top-level window, mapped or not, on any other local X display: every
  display with a socket in `/tmp/.X11-unix` or an abstract one in `/proc/net/unix` (a server
  can run with only the latter). Each Caboose Display instance has its own X cookie, so to
  open another display the helper tries the caller's `XAUTHORITY` and then each instance's
  `$XDG_RUNTIME_DIR/caboose-display/<instance>/Xauthority`. A process with windows on two
  displays is not read at all;
- `act` re-checks all of this, and that the id's window is still on the display, before it
  touches anything.

An agent therefore cannot list, read or press the owner's X11 windows, and an owner
element's id passed with `--display :101` is "element not found". A display the helper
cannot open with any of those authorities is not scanned; in Caboose both displays belong to
`caboose`, whose runtime directory holds both cookies.

### Accessibility switched on

Apps build an accessibility tree only when asked. The computer asks them through:

- `ACCESSIBILITY_ENABLED=1` (Chromium, Electron), `GNOME_ACCESSIBILITY=1` (Firefox) and
  `QT_LINUX_ACCESSIBILITY_ALWAYS_ON=1` (Qt) in both display units and the container image's
  environment, and in what the `launch` tool starts (which also drops any inherited
  `NO_AT_BRIDGE` and `GTK_A11Y=none`);
- `toolkit-accessibility=true` as the default of `org.gnome.desktop.interface` (a GSettings
  override), which at-spi-bus-launcher reports as `org.a11y.Status.IsEnabled`, so apps
  started without that environment still expose a tree;
- `/etc/chromium.d/caboose-accessibility` (from `chromium-accessibility`):
  `ACCESSIBILITY_ENABLED=1` and `--force-renderer-accessibility`, without which Chromium
  shows its frame but not the page;
- `~/.vscode/argv.json` `"force-renderer-accessibility": true` for VS Code.

`press` on an element without an action whose window is not shown, and `set-text` on a field
that cannot take focus, say so instead of pretending.

## Install

`install.sh` (run as root by the image and container builds, after Node and the apps):

- copies `caboose-desktop-mcp.mjs` to `/opt/caboose/desktop-mcp.mjs` and `a11y.py` to
  `/opt/caboose/a11y.py`;
- installs the Chromium flags file, the GSettings override and VS Code's `argv.json` (merged
  into an existing one, owned by `caboose`);
- registers nothing per agent: caboose-agentd hands the server to each ACP agent.

**Runtime:** Node (no packages), python3 with `python3-pyatspi` and `python3-gi`,
at-spi2-core, dbus-x11 (`dbus-launch`), `xdotool`, `wmctrl`, `xprop`, `xwininfo` and
ImageMagick (`import`, `convert`), all in both images. `CABOOSE_AGENT_DISPLAY` sets the
display (default `:101`).

## Test

- `node selftest.mjs` checks the protocol, the tool list and its order, schemas, argument
  validation, and that helper failures come back as tool errors, without an X server.
- `./check-a11y.sh [--rmi]` exercises the helper and the server in real X sessions under
  Docker on any amd64 or arm64 machine; no KVM. It builds the image `caboose-a11y-check` from
  `check/Dockerfile` (Debian 13 with Xvfb, Xwayland, D-Bus, at-spi2-core, Mousepad, Chromium,
  Node, and Caboose Display built from this checkout), runs `check/run.sh` in a throwaway
  container with this directory mounted read-only, and removes the container (`--rmi`
  removes the image too). It prints PASS or FAIL per assertion and exits 1 if any failed:
  - **install.sh**, run twice: the helper and server are installed, the Chromium flags file
    and the GSettings default are in place, no agent configuration is written, VS Code's
    `argv.json` has the switch, and everything under the home is owned by uid 1000.
  - **Two Xvfb displays, `:100` and `:101`, sharing one session bus and registry**, with
    Mousepad and a GTK window on `:100` and a GTK dialog (`check/fixture.py`) on `:101`. The
    helper runs as `caboose` with nothing in its environment but `DISPLAY`
    (`runuser -u caboose -- env -i DISPLAY=… python3 /opt/caboose/a11y.py`). `elements`
    lists the dialog's Save and Cancel buttons, field and check box with bounds; `find`
    returns only the agent's Save; `act press` clicks it and toggles the check box;
    `set-text` writes the field, including a value that starts with a dash; `focus` works;
    `text` returns the label and field; after `bus` publishes a new bus, apps on the earlier
    one are still found.
  - **Isolation**: nothing of `:100` (pids, windows, text) appears in `:101` results, an
    owner element's id is rejected on `:101` with exit 3 and the owner's window is untouched,
    and a process with windows on both displays is not read.
  - **Stale ids**: a changed fingerprint, an unknown path, a malformed id and an id from a
    closed window are rejected with exit 3, and the replacement window is untouched.
  - **Both Caboose Display instances as the computer runs them**: the owner's display
    (Xwayland `:110`) and the agent seat (`--x11-only`, Xwayland `:101`), each with its own
    session bus. Both write their launch environment; the seat's names no Wayland socket and
    sets `GDK_BACKEND=x11`; each has its own X authority; `bus` gives each display its own
    accessibility bus and `AT_SPI_BUS`. With each seat's launch environment, an owner app on
    Xwayland is accessible, an agent app is found and pressed with nobody watching, the
    agent seat lists no owner window, and the owner's window is untouched.
  - **Coordinate tools on the agent seat with nobody watching**, through
    `caboose-desktop-mcp` over stdio: the dialog is viewable with no client attached;
    `click`, `key` and `type` fill its field; `click` presses Save; `screenshot` shows the
    new window rather than a blank seat.
  - **Chromium on the agent seat**, configured only by the installed flags file: a link, a
    button and a field inside a local page are listed; `set-text` (twice, replacing) and
    `press` run the page's script; `text` returns the page text and the followed link; and
    the server's `find` and `read_text` work against the page.
