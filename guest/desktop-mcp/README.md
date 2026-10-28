# caboose-desktop-mcp

An MCP server (stdio, JSON-RPC 2.0) that lets an agent see and drive GUI apps on the agent seat, display `:101`, without ever touching
the owner's display. Beside it, `a11y.py` reads and acts on a display's accessibility tree;
the desktop tools use it on `:101`, and caboose-host's `/v1/screen` routes use it on `:100`.

## Tools

The accessibility tools come first in the tool list, and their descriptions tell the model
to prefer them: they answer in milliseconds, need no screenshot and no image tokens, and act
on a control by id rather than by guessed coordinates.

| Tool | Arguments | Does |
| --- | --- | --- |
| `elements` | — | the focused window's controls: `{ window: { title, app }, elements: [{ id, role, name, states, bounds }] }` |
| `find` | `query`, `role?` | elements whose name contains `query` (case-insensitive), optionally of one role |
| `click_element` | `id` | press it: its AT-SPI action, else a click at its centre |
| `set_text` | `id`, `text` | replace an editable element's text |
| `read_text` | — | the focused window's readable text, page text included |
| `screenshot` | `window?` | PNG of the display or one window |
| `list_windows`, `focus` | `window` | windows with geometry; raise one |
| `click`, `drag`, `type`, `key`, `scroll` | coordinates, text, keys | pointer and keyboard by coordinates |
| `launch` | `command` | start an app on `:101`, with the accessibility environment below |

A failure comes back as a tool error with a sentence the model can act on; an id that no
longer resolves says to list the window again.

caboose-agentd passes the server to every agent in ACP `session/new` (with
`CABOOSE_AGENT_DISPLAY=:101`) and answers the agent's permission requests itself, so
asking before acting needs nothing from this server.

## `a11y.py`

python3 with the AT-SPI bindings from `python3-pyatspi`, and libX11 through ctypes. It runs as
user `caboose` and always prints one JSON object:

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
  contains the query. `--role button` matches `button`, `toggle button` and `radio button`.
- `act`: `{ "ok": true }`. `press` performs the element's own action (`click`, `press`,
  `activate`, `jump`, `toggle`, `open`); only an element with none is clicked at its centre
  with xdotool. `focus` uses Component.grab_focus. `set-text` uses EditableText; a field
  without it (Chromium's and Electron's) is focused through AT-SPI and typed into with
  `xdotool --window`, which sends the keys to that one X window. An unknown, stale or
  vanished id exits 3 with `{ "ok": false, "error": "element not found" }`.
- `text`: `{ "window": {...}, "text": "..." }`: labels, field contents and documents, with
  each embedded object (a link in a paragraph, a paragraph in a page) expanded where it sits;
  at most 20000 characters, with `"truncated": true` when cut.
- `bus`: `{ "address", "source" }`; see below.

When a list is empty for a reason — no window, a window whose application exposes no tree,
an application with windows on two displays — `note` says so, and the agent falls back to
`screenshot`. Other failures exit 1 with `{ "error": … }` (`{ "ok": false, … }` for `act`);
bad arguments exit 2. Walks are bounded (8000 nodes, depth 48, 8 seconds).

**Element ids** look like `600007-1342-1.0.3.0.1-edc227`: the X window the element was
listed from, the application's pid, the child-index path from the application, and a hash of
the element's role and name. An id resolves only while that window is still on the display,
owned by that pid, and the element at that path still has that role and name, so a stale id
is rejected rather than pressing whatever now sits at that path. Treat ids as opaque.

### Which accessibility bus

caboose-host runs the helper from a root exec channel as
`runuser -u caboose -- … python3 /opt/caboose/a11y.py …` with only `DISPLAY` known, so the
helper finds the bus itself, trying in order:

1. `AT_SPI_BUS_ADDRESS`, if the caller set it (then nothing else);
2. the `AT_SPI_BUS` property on the display's root window, which at-spi-bus-launcher sets
   when the session bus that started it knows the display; every toolkit (libatspi,
   atk-bridge, GTK 4, Qt, Chromium) reads it before its session bus, so it is what makes all
   apps on a display share one bus;
3. the a11y bus of a session bus started for that display: Xpra's (Xpra records it as
   `DBUS_SESSION_BUS_ADDRESS` on the root window when it runs one) or D-Bus's X11 autolaunch
   bus for this user;
4. the a11y bus of `$DBUS_SESSION_BUS_ADDRESS`, then of `/run/user/<uid>/bus`.

libatspi binds one bus per process, so when the focused window's application is not on the
first bus found, the helper runs itself again against the next one.

`a11y.py bus --display :N --wait 30` makes step 2 hold. If the display has no `AT_SPI_BUS`,
it asks a session bus started for the display for its a11y bus, and failing that starts one
with `dbus-launch --exit-with-x11` (it ends with the X server), whose at-spi-bus-launcher
then publishes `AT_SPI_BUS`. The computer runs it as each display starts — `ExecStartPost=`
in `caboose-xpra.service` and `caboose-xpra-agent.service`, and `caboose-session` in the
container — before any app, so the owner's display and the agent seat each get their own
bus. It is safe to repeat.

### Display isolation

The displays can still share a bus and its registry (in the container both are started with
one session bus, and an app may have joined it before `AT_SPI_BUS` existed). So the helper
keeps to applications on the requested display by process:

- the focused window is `_NET_ACTIVE_WINDOW` on that display, else its X input focus, else the
  topmost client (Xpra sets no active window while no client is attached);
- its application is the AT-SPI application whose pid is that window's `_NET_WM_PID`;
- that pid must own no top-level window, mapped or not, on any other local X display: every
  display with a socket in `/tmp/.X11-unix` or an abstract one in `/proc/net/unix` (a server
  can run with only the latter) that the user can open. A process with windows on both
  displays is not read at all;
- `act` re-checks all of this, and that the id's window is still on the display, before it
  touches anything.

An agent therefore cannot list, read or press the owner's windows, and an owner element's id
passed with `--display :101` is "element not found". Displays the user cannot open are not
scanned, which in Caboose never applies (both displays are user `caboose`'s).

### Accessibility switched on

Apps only build a tree when asked, and Xpra's packaged config asks them not to. The image
and the container set:

- `--env=NO_AT_BRIDGE=0 --start-env=GTK_A11Y=atspi` on both Xpra displays, overriding the
  `NO_AT_BRIDGE=1` and `GTK_A11Y=none` in `/etc/xpra/conf.d`, which switch off GTK 3's and
  GTK 4's bridges for every app Xpra starts;
- `ACCESSIBILITY_ENABLED=1` (Chromium, Electron), `GNOME_ACCESSIBILITY=1` (Firefox) and
  `QT_LINUX_ACCESSIBILITY_ALWAYS_ON=1` (Qt) in the displays' environment, and in what the
  `launch` tool starts (which also drops any inherited `NO_AT_BRIDGE`);
- `toolkit-accessibility=true` as the default of `org.gnome.desktop.interface` (a GSettings
  override), which at-spi-bus-launcher reports as `org.a11y.Status.IsEnabled`, so apps
  started without that environment still expose a tree;
- `/etc/chromium.d/caboose-accessibility` (from `chromium-accessibility`):
  `ACCESSIBILITY_ENABLED=1` and `--force-renderer-accessibility`, without which Chromium
  shows its frame but not the page;
- `~/.vscode/argv.json` `"force-renderer-accessibility": true` for VS Code.

### The agent seat with nobody watching

Xpra's seamless server parks each window in an unmapped "corral" until a client shows it, so
while no client is attached to the agent seat its windows are unviewable: pointer clicks and
XTEST typing reach nothing. Before every coordinate tool (`screenshot`, `list_windows`,
`focus`, `click`, `drag`, `type`, `key`, `scroll`) the server asks Xpra to map each managed
window that is not viewable (`xpra control :101 map <wid>`, about 80 ms, only for windows
that need it), so the tools work whether or not anyone is watching. A watched seat's windows
are already viewable and are left alone. Xpra also redirects every window off screen and its
root is a large empty canvas, so `screenshot` without a window captures each viewable window
and lays them out in screen coordinates, bottom to top, rather than capturing the root.
The accessibility tools need none of this. `press` on an element without an action, and
`set-text` on a field Chromium cannot type into, say so instead of pretending.

## Install

`install.sh` (run by the image and container builds as root, after the apps):

- copies `caboose-desktop-mcp.mjs` to `/opt/caboose/desktop-mcp.mjs` and `a11y.py` to
  `/opt/caboose/a11y.py`;
- installs the Chromium flags file, the GSettings override and VS Code's `argv.json`;
- registers nothing per agent: caboose-agentd hands the server to each ACP agent in
  `session/new`.

**Runtime:** Node (no packages), python3 with `python3-pyatspi`, at-spi2-core, dbus-x11
(`dbus-launch`), `xdotool`, `wmctrl` and ImageMagick's `import`, all in the image.
`CABOOSE_AGENT_DISPLAY` overrides the display (default `:101`).

## Test

- `node selftest.mjs` checks the protocol, the tool list and its order, schemas, argument
  validation, and that helper failures come back as tool errors, without an X server.
- `./check-a11y.sh` proves the helper in a real X session under Docker on any amd64 or arm64
  machine; no KVM. It builds `caboose-a11y-check` from `check/Dockerfile` (Debian 13 with
  Xvfb, Xpra 6.5.5 from its signed repository, D-Bus, at-spi2-core, Mousepad, Chromium and
  Node), runs `check/run.sh` in a throwaway container with this directory mounted read-only,
  and removes the container (`--rmi` removes the image too). Every helper call is made the way
  caboose-host makes it: `runuser -u caboose -- env -i DISPLAY=… python3 /opt/caboose/a11y.py`.
  It prints PASS or FAIL per assertion:
  - `install.sh`, run twice over existing settings: files installed, settings merged once,
    everything under the home owned by uid 1000;
  - Xvfb `:100` and `:101` sharing one session bus and registry, with Mousepad and a GTK
    window on `:100` and a GTK dialog (`check/fixture.py`) on `:101`: `elements` lists the
    dialog's Save and Cancel buttons, field and check box with bounds; `find` returns only the
    agent's Save; `act press` clicks it and toggles the check box, `set-text` writes the
    field, `focus` works, each seen in the fixture's log; `text` returns the label and field;
    an app on an earlier bus is still found after `bus` publishes a new one;
  - isolation: nothing of `:100` (pids, windows, text) appears in `:101` results, an owner
    element's id is rejected on `:101` and the owner's window is untouched, and a process with
    windows on both displays is not read;
  - stale ids: a changed fingerprint, an unknown path, a malformed id and an id from a closed
    window are all rejected with exit 3, and the replacement window is untouched;
  - Xpra seamless `:100` and `:101` with the units' accessibility options and `bus` run as at
    display start: each display gets its own bus and `AT_SPI_BUS`; an app started by Xpra is
    accessible; an app started like an agent task is found and pressed with no client
    attached; Chromium, configured only by the installed flags file, lists a link, a button
    and a field inside a local page, `set-text` (twice, replacing) and `press` run the page's
    script, `text` returns the page text and the followed link;
  - the coordinate tools on Xpra's agent seat with no client attached: the dialog starts
    unviewable and is viewable once a tool runs; `click`, `key` and `type` fill its field;
    `click` presses Save; `screenshot` returns the window's pixels, not a blank seat;
  - `caboose-desktop-mcp` over stdio: `find` and `read_text` against that page.
