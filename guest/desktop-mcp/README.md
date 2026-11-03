# caboose-desktop-mcp

An MCP server (stdio, newline-delimited JSON-RPC 2.0) that lets an agent see and drive GUI
apps on the agent seat without touching the owner's display. The agent seat is its own
Caboose Display instance. Beside the server are helpers that caboose-host's `/v1/screen`
routes and caboose-display use on the owner's display too:

- `a11y.py` reads and acts on a seat's focused window through its accessibility tree;
- `seat.py` is the client of a seat's control socket (`CABOOSE_DISPLAY_CONTROL`): the
  window list, the seat's own pointer and keyboard, and pictures;
- `caboose-targets.py` is the touch target provider caboose-display runs while a phone aims
  touches ([docs/display.md, "Touch targets"](../../docs/display.md#touch-targets)):
  `serve` prints the focused window's controls whenever they change, `snapshot [--method
  walk|collection] [--repeat N]` prints one reading with how long it took. It reads through
  `a11y.py`, by one AT-SPI Collection call where the application implements it (the ATK
  bridge does, in the application's process) and by walking the tree where not.

Wayland and X11 (Xwayland) applications are read and driven alike: windows, focus and
processes come from the compositor, contents from AT-SPI, and input goes through the
seat, never through X.

## Tools

Three tools, with short definitions: they go to the model on every turn.

| Tool | Arguments | Does |
| --- | --- | --- |
| `look` | `find?`, `text?`, `windows?` | the focused window's controls, one line each (below); `find` keeps those whose name contains it (case-insensitive); `text` adds the window's readable text (documents, pages, terminals); `windows` lists every window with its id and position |
| `act` | `steps`, `observe?` | 1–30 steps in order, stopping at the first failure, then what changed |
| `screenshot` | `window?`, `marks?` | PNG of the seat or one window; `marks` numbers the controls on it and lists them with their ids and centres |

A step is an object with one verb: `{"press": id}` (the control's AT-SPI action, else a
click at its centre), `{"set": id, "text": t}` (replace a field's text; a number for a spin
button or slider goes in through its Value), `{"key": "ctrl+s"}`, `{"type": t}`,
`{"click": [x, y], "button": 1-3, "count": 1-3}`, `{"scroll": [x, y], "dx": n, "dy": n}`,
`{"drag": [x1, y1, x2, y2]}`, `{"focus": window}`, `{"wait": ms}` (10–5000) and
`{"launch": "command"}` (an application on the agent seat, with the accessibility
environment below). An element step whose id no longer names that control (the window lost
focus, or the control changed or went) fails as a `stale id` and does nothing, so it is safe
to retry with the ids of a new `look`. A pointer step at a control first checks that no other
application's window covers it. `act` replies `Done.` (or how many steps ran and why it stopped), then the changes;
`observe: false` skips the settle and the read.

In a Chromium window on the agent seat, `look` also lists the page's tools (WebMCP tools the
page declares, and tools derived from its forms, links and buttons, marked `[derived]`) as
`name(param: type, …) — description`, and the step `{"tool": name, "args": {...}}` calls one
and returns its result; see [guest/webmcp](../webmcp/README.md).

A failure comes back as a sentence the model can act on; an id that no longer resolves says
to look again. The server's `initialize` reply carries one line of `instructions`.
`CABOOSE_DESKTOP_TRACE=FILE` appends one JSON line per tool call (`tool`, `ms`, reply
`chars`, `images`), for measuring. `CABOOSE_DESKTOP_PAGE_TOOLS=0` leaves page tools out, to measure the
accessibility path alone.

### Observations

An observation is compact text (`observation.mjs`). The first one, and every `look`, names
the focused window (the others only as a count) and lists its controls:

```
In dialog 9 "Save As" (mousepad) of 7, focused (1 other window)
e14 text "Name" = "notes.txt" [editable, focused]
e15 button "Save"
```

Each control has a short id (`e14`) that names the same control for as long as the server
runs; tools take short ids or the full element ids. After an action, the observation holds
only the changes since the previous one: windows `Opened`, `Closed` or `Retitled`, where
focus went, and the focused window's controls added (`+`), changed (`~`, the whole new line)
or removed (`- e14`). A window seen for the first time is listed whole. Bounds are left
out; `screenshot` with `marks` gives positions when coordinates are needed.

A window with no accessibility tree (SDL, games, custom-drawn toolkits) is still described:
`look` returns its picture and, with Tesseract installed, the lines of text OCR finds in it
with their centres in seat coordinates, both marked as read from pixels. An X11 window that
does not report its process is matched to the one application with a window of its title.

These tools are the seat's assistive technology, and say so: before the first read and
before each launch the server sets `org.a11y.Status.ScreenReaderEnabled` on the seat's
accessibility bus, as a screen reader does, and Chromium, Electron and other toolkits that
build their whole tree only for one then expose it.

Run `node --test guest/desktop-mcp/ensure-agent-seat.test.mjs` and
`node guest/desktop-mcp/selftest.mjs` from the repository root to check startup coordination
and the MCP protocol. The real display checks below exercise the guest on Linux.

caboose-agentd passes the server to every agent in ACP `session/new` (and on resume and
load) as `caboose-desktop`. The first GUI tool call starts the agent seat through the
guest's privileged seat helper, then reads its launch environment from
`/run/caboose/agent-display.env`: `CABOOSE_AGENT_DISPLAY` (its X display, default `:101`),
`WAYLAND_DISPLAY`, `CABOOSE_DISPLAY_CONTROL`, `XAUTHORITY`, `XDG_RUNTIME_DIR`,
`DBUS_SESSION_BUS_ADDRESS`, the toolkit backends and the video passthrough variables. The
agent runner answers the agent's permission requests itself, so asking before acting needs
nothing from this server.

Coordinates are the seat's logical pixels: the screenshot's pixels and the elements'
bounds. `screenshot` without a window is every window composed bottom to top over the
seat's displays on a dark background, rendered by the compositor. A seat nobody watches
lets applications draw once a second, so `seat.py` asks the compositor to let them draw
(`settle`) before it takes a picture. Every tool works with no client attached.

Before the read that follows an `act`, the server lets the
seat settle on the compositor's commit record: after a press, until the first commit after
it (at most 150 ms); after a text edit, until no window committed for 30 ms (at most
300 ms). It does not guarantee an application has finished navigation.

Control lines include an optional value (up to 200 characters) for editable fields, selected
options and numeric controls. Password and sensitive fields omit values. Values never
contribute to ID fingerprints. `screenshot` with `marks` numbers the focused window's
visible controls on the picture and lists each mark with its short id, role, name and centre
in seat coordinates.

The server keeps one accessibility worker and one seat worker warm, serializes requests
and whole `act` runs, and closes helpers on EOF or termination. Workers restart after exit
or timeout on the next call. A lost response is never replayed automatically because an
input may already have executed. Cached seat environments are checked through the control
socket, avoiding repeated privileged startup and any watcher-replacing display hello.

## `seat.py`

Python 3, standard library only. It talks to the control socket named by
`CABOOSE_DISPLAY_CONTROL` (in each seat's launch environment) and prints one JSON object:

```sh
seat.py windows                          # {"windows": [...], "focused": ID, "bounds": [x, y, w, h]}
seat.py click X Y [--button left|middle|right] [--count 1|2|3]
seat.py drag X1 Y1 X2 Y2
seat.py scroll X Y DX DY                 # wheel clicks; positive DY scrolls down
seat.py key -- COMBO...                  # ctrl+s, alt+F4, shift+Tab, Return
seat.py type -- TEXT
seat.py focus ID
seat.py screenshot [--window ID] --out FILE.png
```

A refusal (no window at that position, an unknown key) exits 1 with `{"error": …}`; bad
arguments exit 2. As a module it is `Seat`, plus `pids_on_other_seats`, which `a11y.py` uses
to keep to one seat. The request format is in
[`docs/architecture.md` § Displays](../../docs/architecture.md#displays).

## `a11y.py`

Python 3 with the AT-SPI bindings from `python3-pyatspi`, and libX11 through ctypes. It runs
as user `caboose` with the seat's launch environment and always prints one JSON object:

```sh
a11y.py elements --display :101
a11y.py find     --display :101 --query save [--role button]
a11y.py act      --display :101 --element ID --action press|focus|set-text [--text T]
a11y.py text     --display :101
a11y.py bus      --display :101 [--wait SECONDS]
a11y.py serve    --display :101
```

- `elements`: `{ "window": { "title", "app" }, "elements": [{ "id", "role", "name", "states",
  "bounds": { "x", "y", "width", "height" } }] }`. The focused window's visible buttons,
  links, fields, check boxes, radio buttons, menus and menu items, tabs, combo boxes, sliders,
  named list, tree and table items, and headings, plus any menu it has open, at most 200, in
  tree (reading) order. Roles are AT-SPI's names (`button`, `entry`, `link`, `check box`,
  `page tab`, …); states are drawn from `focused`, `checked`, `pressed`, `selected`,
  `expanded`, `collapsed`, `editable`, `mixed`, `required`, `invalid`, `read-only`,
  `multi-line`, `visited` and `disabled`. Bounds are in the seat's logical pixels. An
  unnamed field takes the name of its label.
- `find`: the same shape, for every showing element of the focused window whose name
  contains the query. A role matches when it equals the given role or contains it as a word,
  so `--role button` matches `button`, `toggle button` and `radio button`.
- `act`: `{ "ok": true }`. `press` performs the element's own action (`click`, `press`,
  `activate`, `jump`, `toggle`, `open`); only an element with none is clicked at its centre
  with the seat's pointer. `focus` uses `Component.grab_focus`. `set-text` uses
  `EditableText`; for a field without it (Chromium's and Electron's), its window gets the
  keyboard, the field is focused through AT-SPI, and the seat's keyboard selects all,
  deletes and types the text. An unknown, stale or vanished id exits 3 with
  `{ "ok": false, "error": "element not found" }`.
- `text`: `{ "window": {...}, "text": "..." }`: labels, field contents and documents, with
  each embedded object (a link in a paragraph, a paragraph in a page) expanded where it sits;
  at most 20000 characters, with `"truncated": true` when cut.
- `bus`: `{ "address", "source" }`; see below.
- `serve`: newline-delimited JSON requests on stdin with `op` (`elements`, `find`, `act`,
  `text`) and the corresponding CLI option names; one JSON response per request. The
  display is fixed for the worker lifetime. Python/GI and the AT-SPI connection stay warm;
  queued accessibility events refresh the normal libatspi cache between requests;
  a bus fallback executes a bounded single-call helper against the next bus. Existing CLI
  commands and `act`'s `{ "ok": true }` response remain unchanged.

When a list is empty for a reason (no window, a window whose application exposes no tree,
an application with windows on two displays), `note` says so, and the agent falls back to
`screenshot`. Other failures exit 1 with `{ "error": … }` (`{ "ok": false, … }` for `act`);
bad arguments exit 2. Walks are bounded (8000 nodes, depth 48, 8 seconds). Values that start
with a dash are accepted (`--text -5` or `--text=-5`).

**Element ids** look like `2-1342-1.0.3.0.1-edc227`: the window the element was listed from
(the seat's window id), the application's pid, the child-index path from the application,
and a hash of the element's role and name. An id resolves only while that window is still
on the seat, owned by that pid, and the element at that path still has that role and name,
so a stale id is rejected rather than pressing whatever now sits at that path. Treat ids as
opaque.

### Windows and positions

On a Caboose Display seat the helper takes the windows from the control socket: the focused
window is the one with the keyboard (the window an open menu belongs to, when a menu has
it), and its process is what the compositor knows of its client. The application's
top-level accessible is matched to the window by title, size and activation. Element
positions come from AT-SPI in window coordinates and are placed at the window's root
surface for a Wayland window (client-side shadows included, as toolkits count them), and in
screen coordinates for an X11 window, whose root window is the seat's logical space. A
Wayland menu or popup is placed at the popup surface of the same size.

Run with a plain X display and no control socket, the helper reads that display through X
instead (`_NET_ACTIVE_WINDOW`, `_NET_WM_PID`, xdotool), as the first part of the Docker
check does.

### Which accessibility bus

Callers run the helper as `caboose` with the seat's launch environment: caboose-host from
its root exec channel with `runuser -u caboose -- env <owner launch environment> python3
/opt/caboose/a11y.py …`, the MCP server with the agent seat's. On a seat the helper uses,
in order:

1. `AT_SPI_BUS_ADDRESS`, if the caller set it (then nothing else);
2. the `AT_SPI_BUS` property on the seat's Xwayland root window;
3. the a11y bus of a session bus recorded on the X display, or D-Bus's X11 autolaunch bus;
4. the a11y bus of `$DBUS_SESSION_BUS_ADDRESS`, then of `/run/user/<uid>/bus`.

libatspi binds one bus per process, so when the focused window's application is not on the
first bus found, the helper runs itself again against the next one.

`a11y.py bus --display :N --wait 30` sets this up as each seat becomes ready, before any app
(`ExecStartPost=` in `caboose-display.service` and `caboose-display-agent.service`, and
`caboose-session ready` and `start-agent` in the container). On a seat it gives the seat's
session bus the seat's `DISPLAY`, `XAUTHORITY` and `XDG_RUNTIME_DIR` for the services it
starts (and the systemd user manager, when the session bus is systemd's), so
at-spi-bus-launcher names its socket after the seat's display and the two seats never share
one; asks the session bus for its accessibility bus; and publishes that address as
`AT_SPI_BUS` on the seat's Xwayland. Wayland applications find the bus through the session
bus and X11 applications through `AT_SPI_BUS`, so all of a seat's applications share it. On a
plain X display it publishes the bus of a session bus started for that display, starting one
with `dbus-launch --exit-with-x11` if need be. It is safe to repeat.

### Seat isolation

Seats may share a bus registry (an app can join a bus before the seat's is published). So
the helper keeps to applications on the requested seat by process: the focused window's
application is the AT-SPI application with that window's pid, and that pid must own no
window on any other Caboose Display seat of this user (each seat's control socket under
`$XDG_RUNTIME_DIR/caboose-display/*/` is asked for its windows). On a plain X display the
same rule holds across the local X displays the helper can open. A process with windows on
two seats is not read at all, and `act` re-checks all of this, and that the id's window is
still on the seat, before it touches anything.

An agent therefore cannot list, read or press the owner's windows, and an owner element's
id passed on the agent seat is "element not found".

### Accessibility switched on

Apps build an accessibility tree only when asked. The computer asks them through:

- `ACCESSIBILITY_ENABLED=1` (Chromium, Electron), `GNOME_ACCESSIBILITY=1` (Firefox) and
  `QT_LINUX_ACCESSIBILITY_ALWAYS_ON=1` (Qt) in both display units and the container image's
  environment, and in what the `launch` tool starts (which also drops any inherited
  `NO_AT_BRIDGE` and `GTK_A11Y=none`);
- `toolkit-accessibility=true` as the default of `org.gnome.desktop.interface` (a GSettings
  override), which at-spi-bus-launcher reports as `org.a11y.Status.IsEnabled`, so apps
  started without that environment still expose a tree;

What `launch` starts also gets `XDG_SESSION_TYPE=wayland`: the seat is a Wayland session,
and Chromium and Electron then run as Wayland clients rather than through Xwayland.

`set_text` uses the toolkit's EditableText when the field then reads the new text. Where it
does not (Chromium and Electron have none; Firefox's web fields accept it and change
nothing), the field is focused through AT-SPI, or with the seat's pointer when that does not
take, cleared only if it holds text, typed into once the clearing keys have landed (keys and
an input method's text reach an application by different paths), and read back. A field
that does not read the new text within a second says so in the reply. Element ids name a
control by its place in the tree; when a page moves it, the one showing control of the
window with the same role and name is used.

`press` on an element without an action that is not on screen, and `set-text` on a field
that cannot take focus, say so instead of pretending.

## Install

`install.sh` (run as root by the image and container builds, after Node and the apps):

- copies `caboose-desktop-mcp.mjs` to `/opt/caboose/desktop-mcp.mjs`, and `a11y.py` and
  `seat.py` to `/opt/caboose/`;
- installs the GSettings override;
- registers nothing per agent: caboose-agentd hands the server to each ACP agent.

**Runtime:** Node (no packages), python3 with `python3-pyatspi` and `python3-gi`,
at-spi2-core, and `xprop` (to publish `AT_SPI_BUS`), all in both images; on a plain X
display, also dbus-x11 (`dbus-launch`) and `xdotool`. `CABOOSE_AGENT_DISPLAY` sets the X
display (default `:101`) and `CABOOSE_DISPLAY_CONTROL` the seat.

## Test

- `node --test ensure-agent-seat.test.mjs worker.test.mjs` checks cached startup,
  recovery, warm helpers, timeouts and restart without replay.
- `python3 -m unittest test_a11y.py test_readiness.py` checks password/value handling
  and that readiness sends no WebSocket handshake (the readiness stand-in runs unprivileged).
- `./check-bounded.sh` runs the Linux Docker gate with a two-CPU, 4 GiB, 512-process
  builder (30-minute build timeout) and a two-CPU, 1500 MiB, 256-process test container
  (180-second test timeout). It removes both containers on exit and retains the image ID.
  `CABOOSE_CHECK_IMAGE=sha256:…` reuses an immutable local compatible test image.
- `node selftest.mjs` checks the protocol, the tool list and its order, schemas, argument
  validation, and that helper failures come back as tool errors, without a display.
- `python3 -m unittest test_seat.py` checks `seat.py` against a stand-in control socket:
  single-line requests and text escapes, refusals, pictures read in pieces after `settle`,
  and other seats' processes.
- `./check-a11y.sh [--rmi]` exercises the helper and the server in real X sessions under
  Docker on any amd64 or arm64 machine; no KVM. It builds the image `caboose-a11y-check` from
  `check/Dockerfile` (Debian 13 with Xvfb, Xwayland, D-Bus, at-spi2-core, Mousepad, Chromium,
  Node, and Caboose Display built from this checkout), runs `check/run.sh` in a throwaway
  container with this directory mounted read-only, and removes the container (`--rmi`
  removes the image too). It prints PASS or FAIL per assertion and exits 1 if any failed:
  - **install.sh**, run twice: the helper and server are installed, the GSettings default is
    in place and no agent configuration is written.
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
  - **Both Caboose Display instances as the computer runs them**, each on a session bus of
    its own: each writes its launch environment with its own control socket and X
    authority; `bus` gives each seat the accessibility bus of its session bus, a different
    one per seat, published as `AT_SPI_BUS` on its Xwayland.
  - **The owner's display**, through the helpers as the screen routes run them: a GTK dialog
    running as a native Wayland window is listed with its Save and Cancel buttons, field
    and check box, inside the window's bounds; `set-text`, `press` (toggling the check box
    and pressing Save) work; the seat's keyboard (`seat.py key` and `type`) reaches the
    focused Wayland field; the same dialog as an X11 window on Xwayland is found and
    pressed.
  - **The agent seat with nobody watching**: an agent app is found and pressed, the seat
    lists no owner window, an owner element's id is rejected with exit 3, and the owner's
    window is untouched.
  - **Warm MCP contract**: an `act` run, a stale id stopping it, the changes it reports,
    field values, marked screenshots, and warm `look` timing.
  - **Pointer and keyboard steps**, through `caboose-desktop-mcp` over stdio: `look` with
    `windows` shows the dialog; `click`, `key` and `type` steps at the controls' bounds fill
    its field; a `click` presses Save; `screenshot` shows the new window rather than a blank
    seat.
  - **Chromium as a native Wayland client on the agent seat**, configured only by the
    installed flags file: a link, a button and a field inside a local page are listed;
    `set-text` (twice, replacing) and `press` run the page's script; a `click` at the
    link's bounds follows it; `text` returns the page text and the followed link; and the
    server's `look` with `find` and with `text` work against the page.

### Persistent agent GUI profiles

Agent GUI launches use a private home at
`/home/caboose/.local/share/caboose/agent-seat/home`, with private XDG config, data,
cache and state directories. Applications' HOME- and XDG-based state and
singleton locations therefore belong to the agent seat. The initializer serializes
concurrent starts with a kernel file lock and atomically records its format version.
A crash releases the lock; browser-owned locks are never removed. Existing version-1
agent state is reused, while unknown versions fail with an explicit migration error.
No owner profiles, SQLite databases, WAL files, cookies or extensions are copied.
Agent sign-ins persist in the agent profile; owner browser sign-ins are not imported.

The task runner retains its existing owner HOME and CLI authentication configuration.
Applications an agent starts with desktop MCP's `launch` run on the agent seat in that
private profile, whatever the application; a program the runner starts itself keeps the
owner's home. This is profile routing under one Unix user, not a sandbox against arbitrary
shell commands or explicit owner paths.

Run `python3 guest/desktop-mcp/test_agent_profile.py` for synthetic concurrent startup,
profile persistence, crash-lock release, unknown-version and redirection checks. The tests
use disposable directories and synthetic sign-in bytes, never owner state. Real browser
window routing and browser-specific crash recovery require a disposable Linux display
check; these unit tests do not establish those outcomes.
