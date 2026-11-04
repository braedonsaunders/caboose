#!/usr/bin/env python3
"""Read and act on a seat's focused window through its accessibility tree.

Caboose's computer has two seats, each a Caboose Display instance with its own Xwayland:
the owner's display (:110) and the agent seat (:101). This helper gives an agent, or the
owner's phone, the focused window's controls as JSON, with no screenshot, and acts on them
by id. Wayland and X11 applications are read alike. It always prints one JSON object.

    a11y.py elements --display :101
        {"window": {"title", "app"}, "elements": [{"id", "role", "name", "states",
         "bounds": {"x", "y", "width", "height"}}]}
        The focused window's visible controls and headings (and any menu it has open),
        at most 200, in tree (reading) order. Bounds are in the seat's logical pixels.
    a11y.py find --display :101 --query save [--role button]
        Elements of the focused window whose name contains the query (case-insensitive),
        optionally of one role ("button" matches "push button" and "toggle button").
    a11y.py act --display :101 --element ID --action press|focus|set-text [--text T]
        {"ok": true}. press uses the element's own action (click, press, activate, jump),
        else a pointer click at its centre; a menu on screen is always clicked, since its own
        action can open another menu of its bar. set-text replaces an editable text's contents.
        An unknown, stale or vanished element exits 3 with {"ok": false, "error": "element
        not found"}.
    a11y.py text --display :101
        {"window": {...}, "text": "..."}: the focused window's readable text, page text
        included, at most 20000 characters ("truncated": true when cut).
    a11y.py bus --display :101 [--wait SECONDS]
        {"address", "source"}: the accessibility bus used for that seat, starting it if
        need be. Run when a seat comes up so every app on it shares that bus.

When the list is empty for a reason (no window, an application without an accessibility
tree), "note" says why. Other failures exit 1 with {"error": ...} ({"ok": false, ...} for
act); bad arguments exit 2.

It runs as the desktop user with the seat's launch environment. On a Caboose Display seat
(CABOOSE_DISPLAY_CONTROL set) the windows, the focused one, each window's process and
geometry, and the pointer and keyboard come from the seat's control socket (seat.py); on a
plain X display, from X. Seats may share an accessibility registry, so it keeps strictly to
the applications on the requested seat: an application qualifies only if its process owns
a window on that seat and none on any other.

Element ids are "<window>-<pid>-<child path>-<fingerprint>": the window they were listed
from, the application's pid, the child-index path from the application, and a hash of the
element's role and name. An id resolves only while that window is still on the seat and
the element at that path still has that role and name.
"""

from __future__ import annotations

import argparse
import itertools
import ctypes
import ctypes.util
import hashlib
import json
import os
import pwd
import re
import subprocess
import sys
import time
import warnings

# libatspi marks Action.get_action_name deprecated, yet it is the only binding for the
# action's name; keep stderr for real failures.
warnings.filterwarnings("ignore", category=DeprecationWarning)

MAX_ELEMENTS = 200
MAX_TEXT = 20000
MAX_NAME = 200
MAX_NODES = 8000
MAX_DEPTH = 48
BUDGET_SECONDS = 8.0
NOT_FOUND = 3
# An accessibility bus the caller named in AT_SPI_BUS_ADDRESS; then it is the only one used.
CALLER_BUS = None
SERVING = False
ACTIVE_ARGS = None
WARM_BUS = None


def emit(value, code=0):
    sys.stdout.write(json.dumps(value, ensure_ascii=False) + "\n")
    sys.stdout.flush()
    raise SystemExit(code)


class Failure(Exception):
    """A failure to report as JSON with exit code 1 (or `code`)."""

    def __init__(self, message, code=1):
        super().__init__(message)
        self.code = code


# --- X11, through libX11 directly: no subprocess per property ---------------------------

class XWindowAttributes(ctypes.Structure):
    _fields_ = [
        ("x", ctypes.c_int), ("y", ctypes.c_int), ("width", ctypes.c_int), ("height", ctypes.c_int),
        ("border_width", ctypes.c_int), ("depth", ctypes.c_int), ("visual", ctypes.c_void_p),
        ("root", ctypes.c_ulong), ("class_", ctypes.c_int), ("bit_gravity", ctypes.c_int),
        ("win_gravity", ctypes.c_int), ("backing_store", ctypes.c_int), ("backing_planes", ctypes.c_ulong),
        ("backing_pixel", ctypes.c_ulong), ("save_under", ctypes.c_int), ("colormaps_installed", ctypes.c_int),
        ("colormap", ctypes.c_ulong), ("map_installed", ctypes.c_int), ("map_state", ctypes.c_int),
        ("all_event_masks", ctypes.c_long), ("your_event_mask", ctypes.c_long),
        ("do_not_propagate_mask", ctypes.c_long), ("override_redirect", ctypes.c_int), ("screen", ctypes.c_void_p),
    ]


IS_UNMAPPED, IS_VIEWABLE = 0, 2
_ERROR_HANDLER = ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_void_p, ctypes.c_void_p)


def _load_xlib():
    lib = ctypes.CDLL(ctypes.util.find_library("X11") or "libX11.so.6")
    c_ulong_p = ctypes.POINTER(ctypes.c_ulong)
    lib.XOpenDisplay.restype = ctypes.c_void_p
    lib.XOpenDisplay.argtypes = [ctypes.c_char_p]
    lib.XCloseDisplay.argtypes = [ctypes.c_void_p]
    lib.XDefaultRootWindow.restype = ctypes.c_ulong
    lib.XDefaultRootWindow.argtypes = [ctypes.c_void_p]
    lib.XInternAtom.restype = ctypes.c_ulong
    lib.XInternAtom.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int]
    lib.XGetWindowProperty.argtypes = [
        ctypes.c_void_p, ctypes.c_ulong, ctypes.c_ulong, ctypes.c_long, ctypes.c_long, ctypes.c_int,
        ctypes.c_ulong, c_ulong_p, ctypes.POINTER(ctypes.c_int), c_ulong_p, c_ulong_p,
        ctypes.POINTER(ctypes.c_void_p)]
    lib.XFree.argtypes = [ctypes.c_void_p]
    lib.XGetWindowAttributes.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.POINTER(XWindowAttributes)]
    lib.XTranslateCoordinates.argtypes = [
        ctypes.c_void_p, ctypes.c_ulong, ctypes.c_ulong, ctypes.c_int, ctypes.c_int,
        ctypes.POINTER(ctypes.c_int), ctypes.POINTER(ctypes.c_int), c_ulong_p]
    lib.XQueryTree.argtypes = [
        ctypes.c_void_p, ctypes.c_ulong, c_ulong_p, c_ulong_p, ctypes.POINTER(c_ulong_p),
        ctypes.POINTER(ctypes.c_uint)]
    lib.XGetInputFocus.argtypes = [ctypes.c_void_p, c_ulong_p, ctypes.POINTER(ctypes.c_int)]
    lib.XGetSelectionOwner.restype = ctypes.c_ulong
    lib.XGetSelectionOwner.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
    lib.XSetErrorHandler.argtypes = [_ERROR_HANDLER]
    lib.XSetErrorHandler.restype = ctypes.c_void_p
    return lib


class _XResClientIdSpec(ctypes.Structure):
    _fields_ = [("client", ctypes.c_ulong), ("mask", ctypes.c_uint)]


class _XResClientIdValue(ctypes.Structure):
    _fields_ = [("spec", _XResClientIdSpec), ("length", ctypes.c_long), ("value", ctypes.c_void_p)]


_xres = None


def client_pid(handle, window):
    """The process of the X client that made `window`, from the X server (the X-Resource
    extension): for a program that does not set _NET_WM_PID. None where the server or
    libXRes cannot say."""
    global _xres
    if _xres is None:
        try:
            _xres = ctypes.CDLL(ctypes.util.find_library("XRes") or "libXRes.so.1")
            _xres.XResQueryClientIds.argtypes = [ctypes.c_void_p, ctypes.c_long, ctypes.POINTER(_XResClientIdSpec),
                                                 ctypes.POINTER(ctypes.c_long), ctypes.POINTER(ctypes.POINTER(_XResClientIdValue))]
            _xres.XResGetClientPid.argtypes = [ctypes.POINTER(_XResClientIdValue)]
            _xres.XResGetClientPid.restype = ctypes.c_int
            _xres.XResClientIdsDestroy.argtypes = [ctypes.c_long, ctypes.POINTER(_XResClientIdValue)]
        except (OSError, AttributeError):
            _xres = False
    if not _xres or not handle:
        return None
    spec = _XResClientIdSpec(window, 2)  # XRES_CLIENT_ID_PID_MASK
    count, values = ctypes.c_long(0), ctypes.POINTER(_XResClientIdValue)()
    if _xres.XResQueryClientIds(handle, 1, ctypes.byref(spec), ctypes.byref(count), ctypes.byref(values)) != 0:
        return None
    try:
        for index in range(count.value):
            pid = _xres.XResGetClientPid(ctypes.byref(values[index]))
            if pid > 0:
                return pid
    finally:
        _xres.XResClientIdsDestroy(count, values)
    return None


_xlib = None
# The default handler exits the process on BadWindow; a window can vanish mid-query.
_ignore_errors = _ERROR_HANDLER(lambda display, event: 0)


class Display:
    def __init__(self, name):
        global _xlib
        if _xlib is None:
            _xlib = _load_xlib()
            _xlib.XSetErrorHandler(_ignore_errors)
        self.x = _xlib
        self.name = name
        self.handle = self.x.XOpenDisplay(name.encode())
        if not self.handle:
            raise Failure(f"cannot open display {name}")
        self.root = self.x.XDefaultRootWindow(self.handle)
        self._atoms = {}

    def __del__(self):
        if getattr(self, "handle", None):
            self.close()

    def close(self):
        if self.handle:
            self.x.XCloseDisplay(self.handle)
            self.handle = None

    def atom(self, name):
        if not self._atoms.get(name):  # an atom that does not exist yet may exist later
            self._atoms[name] = self.x.XInternAtom(self.handle, name.encode(), 1)
        return self._atoms[name]

    def _property(self, window, name):
        atom = self.atom(name)
        if not atom:
            return None, 0, 0
        kind, fmt, count, after = ctypes.c_ulong(), ctypes.c_int(), ctypes.c_ulong(), ctypes.c_ulong()
        data = ctypes.c_void_p()
        status = self.x.XGetWindowProperty(self.handle, window, atom, 0, 1 << 16, 0, 0, ctypes.byref(kind),
                                           ctypes.byref(fmt), ctypes.byref(count), ctypes.byref(after),
                                           ctypes.byref(data))
        if status != 0 or not data.value:
            return None, 0, 0
        try:
            if fmt.value == 32:  # 32-bit items arrive as C longs
                items = ctypes.cast(data, ctypes.POINTER(ctypes.c_ulong))
                return [items[i] & 0xFFFFFFFF for i in range(count.value)], 32, kind.value
            if fmt.value == 8:
                return ctypes.string_at(data, count.value), 8, kind.value
            return None, 0, 0
        finally:
            self.x.XFree(data)

    def cardinals(self, window, name):
        value, fmt, _ = self._property(window, name)
        return value if fmt == 32 else []

    def string(self, window, name):
        value, fmt, _ = self._property(window, name)
        if fmt != 8:
            return None
        return value.decode("utf-8", "replace")

    def selection_owner(self, name):
        atom = self.atom(name)
        return self.x.XGetSelectionOwner(self.handle, atom) if atom else 0

    def title(self, window):
        return (self.string(window, "_NET_WM_NAME") or self.string(window, "WM_NAME") or "").strip()

    def app_class(self, window):
        value = self.string(window, "WM_CLASS") or ""
        parts = [part for part in value.split("\0") if part]
        return parts[-1] if parts else ""

    def pid(self, window):
        values = self.cardinals(window, "_NET_WM_PID")
        return values[0] if values else client_pid(self.handle, window)

    def attributes(self, window):
        attrs = XWindowAttributes()
        if not self.x.XGetWindowAttributes(self.handle, window, ctypes.byref(attrs)):
            return None
        return attrs

    def rect(self, window):
        attrs = self.attributes(window)
        if attrs is None:
            return None
        x, y, child = ctypes.c_int(), ctypes.c_int(), ctypes.c_ulong()
        if not self.x.XTranslateCoordinates(self.handle, window, self.root, 0, 0, ctypes.byref(x),
                                            ctypes.byref(y), ctypes.byref(child)):
            return None
        return {"x": x.value, "y": y.value, "width": attrs.width, "height": attrs.height}

    def size(self):
        attrs = self.attributes(self.root)
        return (attrs.width, attrs.height) if attrs else (0, 0)

    def tree(self, window):
        root, parent = ctypes.c_ulong(), ctypes.c_ulong()
        children, count = ctypes.POINTER(ctypes.c_ulong)(), ctypes.c_uint()
        if not self.x.XQueryTree(self.handle, window, ctypes.byref(root), ctypes.byref(parent),
                                 ctypes.byref(children), ctypes.byref(count)):
            return None, []
        result = [children[i] for i in range(count.value)]
        if children:
            self.x.XFree(children)
        return parent.value, result

    def clients(self):
        """Top-level application windows, bottom to top where the order is known."""
        listed = self.cardinals(self.root, "_NET_CLIENT_LIST_STACKING") or self.cardinals(self.root, "_NET_CLIENT_LIST")
        if listed:
            return listed
        # No EWMH window manager: mapped, managed-looking children of the root.
        found = []
        _, children = self.tree(self.root)
        for window in children:
            attrs = self.attributes(window)
            if attrs is None or attrs.override_redirect or attrs.map_state != IS_VIEWABLE:
                continue
            if self.pid(window) is not None or self.string(window, "WM_CLASS") is not None:
                found.append(window)
                continue
            _, inner = self.tree(window)  # a reparenting window manager without EWMH
            found.extend(child for child in inner if self.pid(child) is not None)
        return found

    def focused(self, clients):
        """The active window: _NET_ACTIVE_WINDOW, else the input focus, else the topmost."""
        active = self.cardinals(self.root, "_NET_ACTIVE_WINDOW")
        if active and active[0] in clients:
            return active[0]
        focus, revert = ctypes.c_ulong(), ctypes.c_int()
        self.x.XGetInputFocus(self.handle, ctypes.byref(focus), ctypes.byref(revert))
        window = focus.value
        for _ in range(32):
            if window in (0, 1, self.root):  # None, PointerRoot, the root
                break
            if window in clients:
                return window
            parent, _ = self.tree(window)
            window = parent
        for window in reversed(clients):
            attrs = self.attributes(window)
            # Mapped, if not necessarily viewable: a window can be mapped before it is shown.
            if attrs is not None and attrs.map_state != IS_UNMAPPED:
                return window
        return None


def display_number(name):
    match = re.fullmatch(r"[^:]*:(\d+)(?:\.\d+)?", name)
    if not match:
        raise Failure(f"not an X display: {name}", 2)
    return int(match.group(1))


def local_displays():
    """X display numbers on this machine: their socket files, and their abstract sockets, which
    are all a server may have (a display whose file was never made or was removed still runs)."""
    numbers = set()
    try:
        for name in os.listdir("/tmp/.X11-unix"):
            if match := re.fullmatch(r"X(\d+)", name):
                numbers.add(int(match.group(1)))
    except OSError:
        pass
    try:
        with open("/proc/net/unix") as table:
            for line in table:
                if match := re.search(r"@?/tmp/\.X11-unix/X(\d+)$", line.strip()):
                    numbers.add(int(match.group(1)))
    except OSError:
        pass
    return numbers


def display_authorities():
    """Xauthority files to try for another display: the caller's, then each Caboose Display
    instance's (every instance has its own cookie, in its private directory under the runtime
    directory), so the owner's display and the agent seat can each see the other."""
    files = [os.environ.get("XAUTHORITY")]
    runtime = os.environ.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}"
    try:
        for instance in sorted(os.listdir(os.path.join(runtime, "caboose-display"))):
            files.append(os.path.join(runtime, "caboose-display", instance, "Xauthority"))
    except OSError:
        pass
    seen = []
    for path in files:
        if path and path not in seen and os.path.isfile(path):
            seen.append(path)
    return seen or [None]


def open_other(name):
    """Opens another local display with whichever authority it accepts, or returns None.
    libX11 reads XAUTHORITY when it connects, so it is set for each attempt and restored."""
    saved = os.environ.get("XAUTHORITY")
    try:
        for path in display_authorities():
            if path:
                os.environ["XAUTHORITY"] = path
            try:
                return Display(name)
            except Failure:
                continue
        return None
    finally:
        if saved is None:
            os.environ.pop("XAUTHORITY", None)
        else:
            os.environ["XAUTHORITY"] = saved


def pids_elsewhere(display):
    """Processes with a window on any other local X display we can open."""
    own = display_number(display.name)
    pids = set()
    for number in sorted(local_displays() - {own}):
        other = open_other(f":{number}")
        if other is None:
            continue
        try:
            # Every top-level window counts, mapped or not: a window being opened still
            # means the process is there.
            _, children = other.tree(other.root)
            for window in set(other.clients()) | set(children):
                pid = other.pid(window)
                if pid is not None:
                    pids.add(pid)
        finally:
            other.close()
    return pids


class XScreen:
    """An X display: its windows, the focused one, and the processes on it alone. Element
    bounds on it are root-window (screen) coordinates."""

    def __init__(self, name):
        display_number(name)
        self.display = Display(name)
        self.clients = self.display.clients()
        self.elsewhere = None

    def focused(self):
        return self.display.focused(self.clients)

    def window(self, xid):
        return {"title": self.display.title(xid), "app": self.display.app_class(xid)}

    def title(self, xid):
        return self.display.title(xid)

    def pid(self, xid):
        return self.display.pid(xid)

    def rect(self, xid):
        return self.display.rect(xid)

    def frame_rect(self, xid):
        return self.display.rect(xid)

    def size(self):
        return self.display.size()

    def origin(self, xid):
        return None

    def x11(self, xid):
        return False

    def window_count(self, pid):
        return 1

    def popup_origin(self, pid, size):
        return None

    def bus_display(self):
        return self.display

    def confined(self, pid):
        if self.elsewhere is None:
            self.elsewhere = pids_elsewhere(self.display)
        return pid not in self.elsewhere

    def activate(self, xid):
        pass

    def click(self, xid, x, y):
        """A click at (x, y), which only lands while the window is actually shown."""
        attrs = self.display.attributes(xid)
        if attrs is None or attrs.map_state != IS_VIEWABLE:
            raise Failure("element has no accessible action, and its window is not on screen to click")
        subprocess.run(["xdotool", "mousemove", "--sync", str(x), str(y), "click", "1"],
                       env=dict(os.environ, DISPLAY=self.display.name), check=True, timeout=15,
                       stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)

    def _xdotool(self, *args, timeout=15):
        env = dict(os.environ, DISPLAY=self.display.name)
        subprocess.run(["xdotool", *args], timeout=timeout, env=env, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def clear_text(self, xid):
        """Select all and delete, in that X window alone (xdotool --window)."""
        self._xdotool("key", "--window", str(xid), "ctrl+a", "BackSpace")

    def type_text(self, xid, text):
        self._xdotool("type", "--window", str(xid), "--delay", "4", "--", text, timeout=120)

    def let_draw(self):
        pass


class SeatScreen:
    """A Caboose Display seat through its control socket (seat.py): Wayland and X11 windows
    alike, with each one's process, geometry and focus from the compositor. Bounds are in the
    compositor's logical space. An X11 (Xwayland) window's elements report it directly; a
    Wayland window's report positions within their surface, placed at the surface's origin."""

    def __init__(self, name):
        from seat import Seat, SeatError
        self.SeatError = SeatError
        try:
            self.seat = Seat()
            listing = self.seat.windows()
        except SeatError as error:
            raise Failure(str(error)) from None
        windows = listing.get("windows", [])
        self.records = {w["id"]: w for w in windows}
        self.clients = [w["id"] for w in windows]
        self._focused = listing.get("focused")
        bounds = listing.get("bounds") or [0, 0, 0, 0]
        self._size = (bounds[0] + bounds[2], bounds[1] + bounds[3])
        self.elsewhere = None
        # The seat's Xwayland, when it has one: where X11 applications find the accessibility bus.
        self.display = None
        if name:
            try:
                self.display = Display(name)
            except Failure:
                self.display = None

    def _owner(self, wid):
        """A popup's owner: the window an open menu belongs to."""
        seen = set()
        while wid in self.records and self.records[wid]["kind"] == "popup" and wid not in seen:
            seen.add(wid)
            parent = self.records[wid].get("parent")
            if parent is None:
                break
            wid = parent
        return wid

    def focused(self):
        if self._focused in self.records:
            return self._owner(self._focused)
        for wid in reversed(self.clients):
            if self.records[wid]["kind"] != "popup":
                return wid
        return None

    def window(self, wid):
        record = self.records[wid]
        return {"title": record.get("title") or "", "app": record.get("app_id") or ""}

    def title(self, wid):
        return (self.records.get(wid) or {}).get("title") or ""

    def pid(self, wid):
        record = self.records.get(wid) or {}
        if record.get("pid") is None and record.get("x11") and self.display is not None:
            # An X11 window the compositor has no process for: the X server knows its client.
            return client_pid(self.display.handle, record["x11"])
        return record.get("pid")

    def rect(self, wid):
        record = self.records.get(wid)
        if record is None:
            return None
        x, y, w, h = record["rect"]
        return {"x": x, "y": y, "width": w, "height": h}

    def frame_rect(self, wid):
        """Where the window's top-level accessible is: its whole surface, for a Wayland window."""
        record = self.records.get(wid)
        if record is None:
            return None
        if record.get("x11"):
            return self.rect(wid)
        x, y, w, h = record["surface"]
        return {"x": x, "y": y, "width": w, "height": h}

    def size(self):
        return self._size

    def origin(self, wid):
        record = self.records.get(wid)
        if record is None:
            return None
        if record.get("x11"):
            return None
        return (record["surface"][0], record["surface"][1])

    def x11(self, wid):
        return bool((self.records.get(wid) or {}).get("x11"))

    def window_count(self, pid):
        return sum(1 for r in self.records.values() if r.get("pid") == pid and r.get("kind") != "popup")

    def popup_origin(self, pid, size):
        """The surface origin of the Wayland popup of `pid` whose surface is `size` (w, h)."""
        for wid in reversed(self.clients):
            record = self.records[wid]
            if record["kind"] != "popup" or record.get("x11") or record.get("pid") != pid:
                continue
            _, _, w, h = record["surface"]
            if abs(w - size[0]) <= 2 and abs(h - size[1]) <= 2:
                return (record["surface"][0], record["surface"][1])
        return None

    def bus_display(self):
        return self.display

    def confined(self, pid):
        if self.elsewhere is None:
            from seat import pids_on_other_seats
            self.elsewhere = pids_on_other_seats(self.seat.path)
        return pid not in self.elsewhere

    def activate(self, wid):
        try:
            self.seat.focus(wid)
        except self.SeatError as error:
            raise Failure(str(error)) from None

    def covering(self, wid, x, y):
        """The window over (x, y) when it is neither `wid` nor another window of its process
        (its dialogs and menus), else None: input there would land on that window."""
        own = (self.records.get(wid) or {}).get("pid")
        for other in reversed(self.clients):  # bottom to top: the last one holding the point wins
            record = self.records[other]
            rx, ry, rw, rh = record["rect"]
            if not (rx <= x < rx + rw and ry <= y < ry + rh):
                continue
            if own is not None and record.get("pid") == own:
                return None
            chain, seen = other, set()
            while chain is not None and chain not in seen:
                if chain == wid:
                    return None
                seen.add(chain)
                chain = (self.records.get(chain) or {}).get("parent")
            return record
        return {"id": None, "title": "", "kind": "nothing"}

    def click(self, wid, x, y):
        covered = self.covering(wid, x, y)
        if covered is not None:
            raise Failure(f"the control is covered by {covered['kind']} {covered['id']} {json.dumps(covered.get('title') or '')} "
                          "at its position; bring its window forward (focus) or close what covers it, then look again")
        try:
            self.seat.click(x, y)
        except self.SeatError as error:
            raise Failure(str(error)) from None

    def clear_text(self, wid):
        try:
            self.seat.key("ctrl+a", "BackSpace")
        except self.SeatError as error:
            raise Failure(str(error)) from None

    def type_text(self, wid, text):
        try:
            self.seat.type(text)
        except self.SeatError as error:
            raise Failure(str(error)) from None

    def let_draw(self):
        """Let applications draw now: a seat nobody watches paces them at once a second, and
        some (Firefox) update what they expose only as they draw."""
        try:
            self.seat.request("settle")
        except self.SeatError:
            pass


def make_screen(name):
    """The seat through its control socket when the display has one, else plain X."""
    if os.environ.get("CABOOSE_DISPLAY_CONTROL"):
        return SeatScreen(name)
    return XScreen(name)


# --- The accessibility bus ---------------------------------------------------------------

def _gio():
    import gi
    gi.require_version("Gio", "2.0")
    from gi.repository import Gio, GLib
    return Gio, GLib


def _connect(address):
    Gio, _ = _gio()
    flags = Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION
    return Gio.DBusConnection.new_for_address_sync(address, flags, None, None)


def _alive(address):
    try:
        _connect(address).close_sync(None)
        return True
    except Exception:
        return False


def _a11y_of_session(address):
    """Ask a session bus for its accessibility bus (D-Bus starts at-spi-bus-launcher)."""
    Gio, GLib = _gio()
    try:
        connection = _connect(address)
        try:
            reply = connection.call_sync("org.a11y.Bus", "/org/a11y/bus", "org.a11y.Bus", "GetAddress", None,
                                         GLib.VariantType.new("(s)"), Gio.DBusCallFlags.NONE, 5000, None)
            return reply.unpack()[0] or None
        finally:
            connection.close_sync(None)
    except Exception:
        return None


def _activation_environment(address, variables):
    """Add `variables` to the environment a session bus starts services with."""
    if not variables:
        return
    Gio, GLib = _gio()
    try:
        connection = _connect(address)
        try:
            connection.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
                                 "UpdateActivationEnvironment", GLib.Variant("(a{ss})", (variables,)), None,
                                 Gio.DBusCallFlags.NONE, 5000, None)
            # A user bus run by systemd starts services as systemd units, from its environment.
            try:
                connection.call_sync("org.freedesktop.systemd1", "/org/freedesktop/systemd1",
                                     "org.freedesktop.systemd1.Manager", "SetEnvironment",
                                     GLib.Variant("(as)", ([f"{k}={v}" for k, v in variables.items()],)), None,
                                     Gio.DBusCallFlags.NO_AUTO_START, 5000, None)
            except Exception:
                pass
        finally:
            connection.close_sync(None)
    except Exception:
        pass


def bus_sources(display):
    """Where this display's accessibility bus may be, most specific first."""
    sources = []
    if CALLER_BUS:
        return [("AT_SPI_BUS_ADDRESS", "a11y", CALLER_BUS)]
    if display is not None:
        root_a11y = display.string(display.root, "AT_SPI_BUS")
        if root_a11y:
            sources.append(("AT_SPI_BUS", "a11y", root_a11y.strip("\0").strip()))
        for label, address in display_session_buses(display):
            sources.append((label, "session", address))
    env_session = os.environ.get("DBUS_SESSION_BUS_ADDRESS")
    if env_session:
        sources.append(("DBUS_SESSION_BUS_ADDRESS", "session", env_session))
    user_bus = f"/run/user/{os.getuid()}/bus"
    if os.path.exists(user_bus):
        sources.append(("user session bus", "session", f"unix:path={user_bus}"))
    return sources


def display_session_buses(display):
    """Session buses started for this display: one recorded on the root window (a session
    that runs its own bus records its address there) and D-Bus's X11 autolaunch bus for this
    user and machine."""
    found = []
    recorded = display.string(display.root, "DBUS_SESSION_BUS_ADDRESS")
    if recorded and recorded.strip("\0").strip():
        found.append(("display session bus", recorded.strip("\0").strip()))
    machine = ""
    for path in ("/var/lib/dbus/machine-id", "/etc/machine-id"):
        try:
            with open(path, encoding="ascii") as handle:
                machine = handle.read().strip()
            if machine:
                break
        except OSError:
            continue
    if machine:
        user = pwd.getpwuid(os.getuid()).pw_name
        owner = display.selection_owner(f"_DBUS_SESSION_BUS_SELECTION_{user}_{machine}")
        address = display.string(owner, "_DBUS_SESSION_BUS_ADDRESS") if owner else None
        if address and address.strip("\0").strip():
            found.append(("autolaunch session bus", address.strip("\0").strip()))
    return found


def resolve_bus(display, start=0, tried=()):
    """The first working accessibility bus from source `start` on: (address, source, next)."""
    sources = bus_sources(display)
    for index in range(start, len(sources)):
        label, kind, address = sources[index]
        a11y = address if kind == "a11y" else _a11y_of_session(address)
        if a11y and a11y not in tried and _alive(a11y):
            return a11y, label, index + 1
    return None, None, len(sources)


class Bus:
    """The accessibility registry, bound to one bus for the life of this process.

    libatspi connects once, so a different bus means a different process: `retry` runs this
    request against the next source when the wanted application is not on this one, through
    one long-lived helper per bus when serving (see `BusWorker`).
    """

    def __init__(self, display):
        state = json.loads(os.environ.get("CABOOSE_A11Y_BUS_STATE") or '{"next": 0, "tried": []}')
        address, label, after = resolve_bus(display, state["next"], tuple(state["tried"]))
        if not address:
            if state["tried"]:
                self.address = None
                return
            raise Failure(f"no accessibility bus found for display {display.name if display else os.environ.get('DISPLAY', '')}")
        self.address, self.label = address, label
        self.state = {"next": after, "tried": state["tried"] + [address]}
        os.environ["AT_SPI_BUS_ADDRESS"] = address
        import gi
        gi.require_version("Atspi", "2.0")
        from gi.repository import Atspi
        self.Atspi = Atspi
        Atspi.init()
        Atspi.set_timeout(2000, 5000)
        self.desktop = Atspi.get_desktop(0)

    def retry(self, display):
        """Re-run against the next bus that might hold the application; False if none."""
        if not self.address:
            return False
        sources = bus_sources(display)
        if self.state["next"] >= len(sources):
            return False
        env = dict(os.environ, CABOOSE_A11Y_BUS_STATE=json.dumps(self.state))
        env.pop("AT_SPI_BUS_ADDRESS", None)
        if SERVING:
            args = ACTIVE_ARGS
            request = {"op": args.command, "display": args.display}
            for key in ("element", "action", "text", "query", "role"):
                value = getattr(args, key, None)
                if value is not None:
                    request[key] = value
            raise ServedResult(BusWorker.ask(json.dumps(self.state, sort_keys=True), env, args.display, request))
        sys.stdout.flush()
        os.execve(sys.executable, [sys.executable, os.path.abspath(__file__)] + sys.argv[1:], env)
        return True  # not reached

    def application(self, pid):
        if not self.address:
            return None
        found = self._application(pid)
        if found is None:
            proxy = sandbox_bus_proxy(pid)
            if proxy is not None:
                found = self._application(proxy)
        return found

    def _application(self, pid):
        # A process can register more than once (Qt's bridge beside another toolkit's, one of
        # them empty): the registration with windows is the application.
        best, most = None, -1
        for index in range(self.desktop.get_child_count()):
            try:
                app = self.desktop.get_child_at_index(index)
                if app is not None and app.get_process_id() == pid:
                    count = app.get_child_count()
                    if count > most:
                        best, most = app, count
            except Exception:
                continue
        return best


# Windows programs under Wine: Wine has no AT-SPI bridge, so caboose-msaa.exe, run in the
# program's own prefix, reads its Win32 controls (wine/caboose-msaa.c). Their element paths
# start with WINE_CONTROL (a child window) or WINE_MENU.
WINE_CONTROL, WINE_MENU = 9000, 9001
MSAA = [os.path.join(os.path.dirname(os.path.abspath(__file__)), "wine", "caboose-msaa.exe"),
        os.path.join(os.path.dirname(os.path.abspath(__file__)), "caboose-msaa.exe")]


def wine_prefix(pid):
    """The Wine prefix of a Windows program's process, or None for any other process."""
    try:
        with open(f"/proc/{pid}/maps") as maps:
            if not any(line.rstrip().endswith(("/ntdll.so", "wine64-preloader", "wine-preloader")) for line in maps):
                return None
        with open(f"/proc/{pid}/environ", "rb") as env:
            values = dict(item.split(b"=", 1) for item in env.read().split(b"\0") if b"=" in item)
    except OSError:
        return None
    prefix = values.get(b"WINEPREFIX") or (values.get(b"HOME", b"") + b"/.wine")
    return prefix.decode(errors="replace")


def wine_bridge(prefix, *fields):
    helper = next((path for path in MSAA if os.path.exists(path)), None)
    if helper is None:
        return None
    request = "\t".join(f.replace("\t", " ").replace("\n", " ") for f in fields) + "\n"
    try:
        done = subprocess.run(["wine", helper], input=request, capture_output=True, text=True, timeout=15,
                              env=dict(os.environ, WINEPREFIX=prefix, WINEDEBUG="-all"))
        return json.loads(done.stdout.splitlines()[0]) if done.stdout.strip() else None
    except (OSError, subprocess.TimeoutExpired, ValueError, IndexError):
        return None


def wine_path(path):
    kind, *rest = path.split(".")
    return [WINE_CONTROL if kind == "w" else WINE_MENU] + [int(i) for i in rest]


def wine_elements(target, prefix):
    """The Win32 controls of the focused window of a program under Wine, as elements."""
    title = target.screen.title(target.xid)
    answer = wine_bridge(prefix, "list", title)
    if not answer or not answer.get("ok"):
        return None
    rect = target.screen.rect(target.xid) or {}
    wx, wy, ww, wh = answer.get("window") or [0, 0, 0, 0]
    sx = (ww / rect["width"]) if rect.get("width") and ww else 1
    sy = (wh / rect["height"]) if rect.get("height") and wh else 1
    found = []
    for e in answer.get("elements", []):
        name = e.get("name") or ""
        fingerprint = hashlib.sha1(f"wine|{e['role']}|{name[:100]}".encode()).hexdigest()[:6]
        element = {"id": element_id(target.xid, target.pid, wine_path(e["path"]), fingerprint), "role": e["role"], "name": name,
                   "states": [st for st in e.get("states", []) if st != "focusable"]}
        x, y, w, h = e.get("bounds") or [0, 0, 0, 0]
        if w and h:
            element["bounds"] = {"x": round(rect.get("x", 0) + (x - wx) / sx), "y": round(rect.get("y", 0) + (y - wy) / sy),
                                 "width": max(1, round(w / sx)), "height": max(1, round(h / sy))}
        actions = ["press"] if e["role"] not in ("label", "panel", "status bar", "tool bar", "page tab list", "menu") and "disabled" not in e.get("states", []) else []
        if "editable" in e.get("states", []):
            actions.append("set-text")
        element["actions"] = actions
        if e.get("value"):
            element["value"] = e["value"][:MAX_NAME]
        found.append(element)
    return found


def titled_pid(bus, title):
    """The process of the one application on the bus with a showing window of this title."""
    if not title or not getattr(bus, "address", None):
        return None
    wanted, found = _norm(title), set()
    for index in range(bus.desktop.get_child_count()):
        try:
            app = bus.desktop.get_child_at_index(index)
            for k in range(min(app.get_child_count(), 20)):
                top = app.get_child_at_index(k)
                if top is not None and _norm(top.get_name()) == wanted:
                    found.add(app.get_process_id())
        except Exception:
            continue
    return found.pop() if len(found) == 1 else None


def sandbox_bus_proxy(pid):
    """A sandboxed process (Flatpak) reaches the accessibility bus through a proxy, so the
    registry knows it by the proxy's process: the one listening on the socket bound into the
    sandbox at /run/flatpak/at-spi-bus. None for a process outside a sandbox."""
    try:
        with open(f"/proc/{pid}/mountinfo") as mounts:
            source = next((line.split()[3] for line in mounts if line.split()[4:5] == ["/run/flatpak/at-spi-bus"]), None)
        if source is None:
            return None
        with open("/proc/net/unix") as sockets:
            inodes = {line.split()[6] for line in sockets if line.split()[-1] == source and line.split()[5] == "01"}
        if not inodes:
            return None
        wanted = {f"socket:[{inode}]" for inode in inodes}
        for candidate in os.listdir("/proc"):
            if not candidate.isdigit():
                continue
            try:
                for fd in os.listdir(f"/proc/{candidate}/fd"):
                    if os.readlink(f"/proc/{candidate}/fd/{fd}") in wanted:
                        return int(candidate)
            except OSError:
                continue
    except (OSError, ValueError, IndexError):
        return None
    return None


class ServedResult(Exception):
    def __init__(self, result):
        self.result = result


class BusWorker:
    """A long-lived helper serving one further accessibility bus, kept for this helper's life.

    Every new AT-SPI client costs each GTK 3 application on its bus three descriptors that
    at-spi2-atk before 2.62 keeps until the application exits, so a reader asks the same
    client again rather than starting a new one per request."""
    workers = {}  # bus state -> Popen

    @classmethod
    def ask(cls, key, env, display, request, timeout=30):
        import selectors
        worker = cls.workers.get(key)
        if worker is None or worker.poll() is not None:
            worker = subprocess.Popen([sys.executable, os.path.abspath(__file__), "serve", f"--display={display}"],
                                      env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1)
            cls.workers[key] = worker
        try:
            worker.stdin.write(json.dumps(request, ensure_ascii=False) + "\n")
            worker.stdin.flush()
            with selectors.DefaultSelector() as selector:
                selector.register(worker.stdout, selectors.EVENT_READ)
                line = worker.stdout.readline() if selector.select(timeout) else ""
            if not line:
                raise OSError("no answer")
            return json.loads(line)
        except (OSError, ValueError):
            worker.kill()
            worker.wait()
            cls.workers.pop(key, None)
            raise Failure("the accessibility helper for another bus did not answer")


def get_bus(display):
    global WARM_BUS
    if not SERVING:
        return Bus(display)
    if WARM_BUS is None:
        WARM_BUS = Bus(display)
        global KNOWN_WINDOWS
        KNOWN_WINDOWS = seat_windows()
    return WARM_BUS


# The seat's windows when this helper registered with the accessibility bus (None off a
# Caboose Display seat). libatspi's cache does not learn of top-level windows created later.
KNOWN_WINDOWS = None


def seat_windows():
    if not os.environ.get("CABOOSE_DISPLAY_CONTROL"):
        return None
    try:
        from seat import Seat
        return {w["id"]: w.get("kind") for w in Seat().windows().get("windows", [])}
    except Exception:
        return None


def needs_registration(op, request):
    """Whether the window a request reads or acts in is a top-level or dialog that appeared
    after this helper last read the registry afresh, so its cache may not hold it."""
    if KNOWN_WINDOWS is None:
        return False
    now = seat_windows() or {}
    if op == "act":
        match = ID_PATTERN.fullmatch(request.get("element") or "")
        target = int(match.group(1), 16) if match else None
    else:
        try:
            from seat import Seat
            target = Seat().windows().get("focused")
        except Exception:
            target = None
    return target is not None and target not in KNOWN_WINDOWS and now.get(target) in ("toplevel", "dialog")


# --- The tree --------------------------------------------------------------------------

def _roles(Atspi, *names):
    return {getattr(Atspi.Role, name) for name in names if hasattr(Atspi.Role, name)}


class Tree:
    def __init__(self, Atspi):
        self.Atspi = Atspi
        S = Atspi.StateType
        self.S = S
        self.actionable = _roles(
            Atspi, "PUSH_BUTTON", "PUSH_BUTTON_MENU", "TOGGLE_BUTTON", "CHECK_BOX", "RADIO_BUTTON", "MENU_ITEM",
            "CHECK_MENU_ITEM", "RADIO_MENU_ITEM", "LINK", "PAGE_TAB", "COMBO_BOX", "SPIN_BUTTON", "SLIDER",
            "ENTRY", "PASSWORD_TEXT", "AUTOCOMPLETE", "EDITBAR", "TERMINAL", "SWITCH")
        self.named_only = _roles(Atspi, "HEADING", "LIST_ITEM", "TREE_ITEM", "TABLE_CELL", "ICON", "MENU",
                                 "TABLE_COLUMN_HEADER", "TABLE_ROW_HEADER", "COLUMN_HEADER", "ROW_HEADER", "ALERT")
        # Controls whose text is their value, not their name.
        self.value_roles = _roles(Atspi, "ENTRY", "PASSWORD_TEXT", "AUTOCOMPLETE", "EDITBAR", "TERMINAL",
                                  "COMBO_BOX", "SPIN_BUTTON", "SLIDER")
        self.editable_roles = _roles(Atspi, "TEXT", "DOCUMENT_TEXT", "PARAGRAPH", "SECTION", "DOCUMENT_WEB")
        self.top_roles = _roles(Atspi, "FRAME", "DIALOG", "WINDOW", "FILE_CHOOSER", "ALERT", "COLOR_CHOOSER",
                                "FONT_CHOOSER", "DOCUMENT_FRAME")
        self.popup_roles = _roles(Atspi, "WINDOW", "MENU", "POPUP_MENU", "TOOL_TIP")
        # Content read as text (look's text) rather than as controls, and containers that list
        # their items: a scrolled area holding one is not unexposed.
        self.text_content_roles = _roles(Atspi, "DOCUMENT_FRAME", "DOCUMENT_WEB", "DOCUMENT_TEXT", "DOCUMENT_SPREADSHEET",
                                         "DOCUMENT_PRESENTATION", "DOCUMENT_EMAIL", "TERMINAL", "TEXT", "PARAGRAPH", "EMBEDDED")
        self.content_roles = self.text_content_roles | _roles(Atspi, "TABLE", "TREE_TABLE", "TREE", "LIST", "LIST_BOX")
        self.block_roles = _roles(
            Atspi, "PARAGRAPH", "HEADING", "SECTION", "LIST", "LIST_ITEM", "TABLE", "TABLE_ROW", "FORM",
            "BLOCK_QUOTE", "ARTICLE", "FOOTER", "HEADER", "LANDMARK", "PANEL", "SEPARATOR", "DOCUMENT_WEB",
            "DOCUMENT_FRAME", "DOCUMENT_TEXT", "FILLER", "TOOL_BAR", "MENU_BAR", "PAGE_TAB_LIST", "GROUPING",
            "DESCRIPTION_LIST", "DESCRIPTION_TERM", "DESCRIPTION_VALUE", "CAPTION", "COMMENT", "FOOTNOTE")
        self.press_actions = ("click", "press", "activate", "jump", "toggle", "open", "check", "uncheck", "showmenu")
        # Selectable items a toolkit gives no action (GTK 3 notebook tabs): on screen, a press is
        # the seat's pointer at their coordinates.
        self.pointer_roles = _roles(Atspi, "PAGE_TAB", "LIST_ITEM", "TREE_ITEM")
        self.state_labels = [
            ("FOCUSED", "focused"), ("CHECKED", "checked"), ("PRESSED", "pressed"), ("SELECTED", "selected"),
            ("EXPANDED", "expanded"), ("EDITABLE", "editable"), ("INDETERMINATE", "mixed"),
            ("REQUIRED", "required"), ("INVALID_ENTRY", "invalid"), ("READ_ONLY", "read-only"),
            ("MULTI_LINE", "multi-line"), ("VISITED", "visited"), ("BUSY", "busy")]
        self.started = time.monotonic()
        self.visited = 0
        self.partial = []  # child counts of containers read in part

    def exhausted(self):
        return self.visited >= MAX_NODES or time.monotonic() - self.started > BUDGET_SECONDS

    def states(self, node):
        try:
            return node.get_state_set()
        except Exception:
            return None

    def fresh_states(self, node):
        try:
            node.clear_cache()
        except Exception:
            pass
        return self.states(node)

    def has(self, states, name):
        state = getattr(self.S, name, None)
        return state is not None and states is not None and states.contains(state)

    def state_names(self, states):
        names = [label for name, label in self.state_labels if self.has(states, name)]
        if self.has(states, "EXPANDABLE") and not self.has(states, "EXPANDED"):
            names.append("collapsed")
        if not (self.has(states, "ENABLED") or self.has(states, "SENSITIVE")):
            names.append("disabled")
        return names

    # A container this large (a spreadsheet's cells, a long list) is read in part: its
    # selected children and the first few, instead of thousands of round trips.
    LARGE = 512
    SAMPLE = 32

    def child_count(self, node):
        try:
            return node.get_child_count()
        except Exception:
            return 0

    def children(self, node):
        try:
            count = node.get_child_count()
        except Exception:
            return []
        indices = range(count)
        if count > self.LARGE:
            chosen, active = set(), None
            try:
                if node.get_selection_iface() is not None:
                    for k in range(min(self.Atspi.Selection.get_n_selected_children(node), self.SAMPLE)):
                        child = self.Atspi.Selection.get_selected_child(node, k)
                        if child is not None:
                            chosen.add(child.get_index_in_parent())
                            active = active or child
            except Exception:
                pass
            # A table (a spreadsheet) is read around its selected cell: the rows and columns a
            # person sees next to it, so values entered nearby show.
            region = self.table_region(node, active)
            chosen |= region if region else set(range(self.SAMPLE))
            indices = sorted(i for i in chosen if 0 <= i < count)
            self.partial.append(count)
        result = []
        for index in indices:
            try:
                result.append((index, node.get_child_at_index(index)))
            except Exception:
                continue
        return result

    def table_region(self, table, active, rows=12, cols=6):
        """Child indices of the cells around `active` (or the top left) of a table."""
        try:
            if table.get_table_iface() is None:
                return set()
            Table = self.Atspi.Table
            row = col = 0
            if active is not None:
                index = active.get_index_in_parent()
                row, col = Table.get_row_at_index(table, index), Table.get_column_at_index(table, index)
            cells, filled = {}, set()
            for r in range(max(0, row - 2), row + rows):
                for c in range(max(0, col - 1), col + cols):
                    cell = Table.get_accessible_at(table, r, c)
                    if cell is not None:
                        cells[(r, c)] = cell.get_index_in_parent()
                        if self.text(cell, 1):
                            filled.add((r, c))
            # The cells holding something, the selected one, and the empty ones next to them
            # (where the next value goes); not every blank cell of the region.
            keep = filled | {(row, col)} | {(r + dr, c + dc) for r, c in filled for dr, dc in ((1, 0), (0, 1), (-1, 0), (0, -1))}
            return {index for at, index in cells.items() if at in keep}
        except Exception:
            return set()

    def text(self, node, limit=None):
        try:
            if node.get_text_iface() is None:
                return None
            Text = self.Atspi.Text
            count = Text.get_character_count(node)
            return Text.get_text(node, 0, count if limit is None else min(count, limit))
        except Exception:
            return None

    def name(self, node, role, states):
        try:
            name = node.get_name() or ""
        except Exception:
            name = ""
        if not name.strip():
            name = self.label(node)
        if not name.strip() and self.has(states, "EDITABLE"):
            name = self.context_name(node)
        if not name.strip():
            try:
                name = node.get_description() or ""
            except Exception:
                name = ""
        if not name.strip() and not self.has(states, "EDITABLE") and role not in self.value_roles:
            name = (self.text(node, MAX_NAME * 2) or "").replace("￼", " ")
        name = " ".join(name.split())
        return name[:MAX_NAME]

    def value(self, node, role, states):
        if role in _roles(self.Atspi, "PASSWORD_TEXT"):
            return None
        try:
            attributes = node.get_attributes() or []
            if isinstance(attributes, dict):
                attributes = [f"{key}:{value}" for key, value in attributes.items()]
            if any(str(a).lower() in ("password:true", "sensitive:true", "text-input-type:password") for a in attributes):
                return None
        except Exception:
            return None
        numeric = role in _roles(self.Atspi, "SPIN_BUTTON", "SLIDER")
        combo = role in _roles(self.Atspi, "COMBO_BOX")
        if self.has(states, "EDITABLE") or role in _roles(self.Atspi, "ENTRY", "AUTOCOMPLETE", "EDITBAR") or numeric or combo:
            value = self.text(node, MAX_NAME)
            if value:
                return value
            try:
                if numeric and node.get_value_iface() is not None:
                    return str(self.Atspi.Value.get_current_value(node))
                if combo and node.get_selection_iface() is not None:
                    child = self.Atspi.Selection.get_selected_child(node, 0)
                    value = child.get_name() if child else None
                    if value and value != self.name(node, role, states):
                        return value[:MAX_NAME]
            except Exception:
                pass
        return None

    def context_name(self, node):
        """An unnamed field's name from where it sits: the combo box it is the entry of (GTK's
        combo box with entry names the box, not the field), else the label just before it among
        its siblings."""
        try:
            parent = node.get_parent()
            if parent is not None and parent.get_role() in _roles(self.Atspi, "COMBO_BOX"):
                named = parent.get_name() or self.label(parent)
                if named and named.strip():
                    return named
            if parent is not None:
                index = node.get_index_in_parent()
                for i in range(index - 1, max(-1, index - 3), -1):
                    sibling = parent.get_child_at_index(i)
                    if sibling is not None and sibling.get_role() in _roles(self.Atspi, "LABEL"):
                        return sibling.get_name() or ""
        except Exception:
            pass
        return ""

    def label(self, node):
        """The name of the element that labels this one (a GTK entry's mnemonic label)."""
        try:
            for relation in node.get_relation_set() or []:
                if relation.get_relation_type() == self.Atspi.RelationType.LABELLED_BY and relation.get_n_targets():
                    return relation.get_target(0).get_name() or ""
        except Exception:
            pass
        return ""

    def bounds(self, node, origin=None):
        """The element's rectangle: screen coordinates (divided by a `Scale` origin), or with
        `origin` (a Wayland surface's position) its window coordinates moved there."""
        try:
            if node.get_component_iface() is None:
                return None
            screen = origin is None or isinstance(origin, Scale)
            rect = self.Atspi.Component.get_extents(node, self.Atspi.CoordType.SCREEN if screen else self.Atspi.CoordType.WINDOW)
        except Exception:
            return None
        if rect.width <= 0 or rect.height <= 0:
            return None
        if isinstance(origin, Scale):
            x, y = round(rect.x / origin), round(rect.y / origin)
            return {"x": x, "y": y, "width": max(1, round((rect.x + rect.width) / origin) - x), "height": max(1, round((rect.y + rect.height) / origin) - y)}
        dx, dy = origin or (0, 0)
        return {"x": rect.x + dx, "y": rect.y + dy, "width": rect.width, "height": rect.height}

    def window_size(self, node):
        """The size of a top-level accessible in its own window coordinates."""
        try:
            rect = self.Atspi.Component.get_extents(node, self.Atspi.CoordType.WINDOW)
            return rect.width, rect.height
        except Exception:
            return None

    def actions(self, node):
        try:
            if node.get_action_iface() is None:
                return None, []
            Action = self.Atspi.Action
            return node, [(Action.get_action_name(node, i) or "").lower() for i in range(Action.get_n_actions(node))]
        except Exception:
            return None, []

    def interesting(self, node, role, states):
        if role in self.actionable:
            return True
        if role in self.editable_roles and self.has(states, "EDITABLE") and self.has(states, "FOCUSABLE"):
            return True
        if role in self.named_only:
            return None  # only with a name
        if self.has(states, "FOCUSABLE"):
            _, names = self.actions(node)
            if any(name in self.press_actions for name in names):
                return None
        return False

    def fingerprint(self, role, name):
        return hashlib.sha1(f"{int(role)}|{name[:100]}".encode()).hexdigest()[:6]

    def walk(self, root, path, visit):
        """Depth-first, in child order, over showing nodes below `root`; `visit` may stop it."""
        stack = [(root, path, 0)]
        while stack:
            if self.exhausted():
                return
            node, node_path, depth = stack.pop()
            self.visited += 1
            states = self.states(node)
            if states is None or (depth > 0 and not self.has(states, "SHOWING")):
                continue
            try:
                role = node.get_role()
            except Exception:
                continue
            if depth > 0 and visit(node, node_path, role, states) is False:
                return
            if depth < MAX_DEPTH:
                for index, child in reversed(self.children(node)):
                    if child is not None:
                        stack.append((child, node_path + [index], depth + 1))


def intersects(bounds, clip):
    if clip is None:
        return True
    return (bounds["x"] < clip["x"] + clip["width"] and bounds["x"] + bounds["width"] > clip["x"]
            and bounds["y"] < clip["y"] + clip["height"] and bounds["y"] + bounds["height"] > clip["y"])


def _norm(text):
    return " ".join((text or "").split()).casefold()


def frame_origin(size, rect, surface, origin):
    """Where a Wayland window's accessible coordinates start. Toolkits measure from different
    corners of a window drawn with its own shadow: GTK 3 from the surface (shadow included),
    GTK 4 from the window's geometry inside it. The top-level accessible's own size says which:
    the geometry's size means the geometry's corner."""
    if not size or not surface:
        return origin
    width, height = size
    near = lambda box: abs(width - box["width"]) <= 2 and abs(height - box["height"]) <= 2
    if near(rect) and not near(surface):
        return (rect["x"], rect["y"])
    return origin


def match_frame(tree, app, screen, wid, active):
    """The application's top-level accessible for window `wid`, and the app's open popups:
    ((index, accessible, origin) or None, [(index, accessible, bounds, origin)], rect)."""
    rect = screen.rect(wid)
    expected = screen.frame_rect(wid)
    origin = screen.origin(wid)
    pid = screen.pid(wid)
    title = _norm(screen.title(wid))
    # Titles of the application's other windows: a top-level named like one of them is that
    # window, not this one.
    others = {_norm(screen.title(w)) for w in screen.clients if w != wid and screen.pid(w) == pid} - {title}
    best, best_score, popups, showing = None, 0, [], []
    for index, top in tree.children(app):
        if top is None:
            continue
        states = tree.states(top)
        if states is None or not (tree.has(states, "SHOWING") or tree.has(states, "VISIBLE")):
            continue
        try:
            role = top.get_role()
            name = _norm(top.get_name())
        except Exception:
            continue
        if role in tree.popup_roles and not name and tree.has(states, "SHOWING"):
            if origin is None:
                popups.append((index, top, tree.bounds(top), None))
            else:
                size = tree.window_size(top)
                at = screen.popup_origin(pid, size) if size else None
                if at is not None:
                    popups.append((index, top, tree.bounds(top, at), at))
        if role not in tree.top_roles:
            continue
        if name and name in others:
            continue
        showing.append((index, top))
        bounds = tree.bounds(top, origin)
        score = 0
        if title and name == title:
            score += 4
        elif title and name and (name in title or title in name):
            score += 2
        if expected and bounds and abs(bounds["x"] - expected["x"]) <= 64 and abs(bounds["y"] - expected["y"]) <= 64 \
                and abs(bounds["width"] - expected["width"]) <= 128 and abs(bounds["height"] - expected["height"]) <= 128:
            score += 3
        if active and tree.has(states, "ACTIVE"):
            score += 2
        if score > best_score:
            best, best_score = (index, top), score
    # The one top-level shown stands for the window only when it is the application's only
    # window: a dialog that has just mapped is not yet in the tree, and its parent is not it.
    if best is None and len(showing) == 1 and screen.window_count(pid) <= 1:
        best = showing[0]
    frame_index = best[0] if best else None
    popups = [popup for popup in popups if popup[0] != frame_index]
    if best is not None and origin is not None and rect is not None:
        origin = frame_origin(tree.window_size(best[1]), rect, expected, origin)
    scale = x11_scale(screen, wid, tree, best[1]) if best else None
    if scale is not None:
        origin = scale
        popups = [(index, top, tree.bounds(top, scale), scale) for index, top, _, _ in popups]
    return ((best[0], best[1], origin) if best else None), popups, rect


def x11_scale(screen, wid, tree, top):
    """For an X11 window on a scaled seat, how its accessible's screen coordinates relate to
    the seat's: a Scale when the toolkit reports Xwayland's pixels (Chromium), None when it
    reports the seat's logical ones already (Qt). Read off the window's own size."""
    if not screen.x11(wid) or top is None:
        return None
    frame = screen.frame_rect(wid)
    if not frame or frame["width"] <= 0 or frame["height"] <= 0:
        return None
    # The window's own extents, and those of its first child: Chromium reports its frame in
    # the seat's pixels and everything inside it in Xwayland's.
    sizes = [tree.window_size(top)] + [tree.window_size(child) for _, child in tree.children(top)[:1] if child is not None]
    ratio = max([(w / frame["width"] + h / frame["height"]) / 2 for w, h in filter(None, sizes) if w > 0 and h > 0], default=1)
    return Scale(ratio) if ratio > 1.25 else None


def top_origin(screen, wid, pid, tree, top):
    """Where the top-level accessible `top` (the window, or one of its popups) is placed:
    None for screen coordinates."""
    origin = screen.origin(wid)
    if screen.x11(wid):
        return x11_scale(screen, wid, tree, top)
    if origin is None or top is None:
        return origin
    size = tree.window_size(top)
    frame = screen.frame_rect(wid)
    rect = screen.rect(wid)
    if size and rect and frame_origin(size, rect, frame, origin) != origin:
        return (rect["x"], rect["y"])
    if size and not (frame and abs(frame["width"] - size[0]) <= 2 and abs(frame["height"] - size[1]) <= 2):
        popup = screen.popup_origin(pid, size)
        if popup is not None:
            return popup
    return origin


class Target:
    """The focused window on the requested display and its accessible application."""

    def __init__(self, display_name):
        self.screen = make_screen(display_name)
        self.bus = None
        self.app = None
        self.note = None
        self.xid = self.screen.focused()
        self.window = self.screen.window(self.xid) if self.xid else None
        if not self.xid:
            self.note = "No window is open on this display."
            return
        self.pid = self.screen.pid(self.xid)
        if self.pid is None:
            # An X11 window without _NET_WM_PID: the application whose window has its title.
            self.pid = titled_pid(get_bus(self.screen.bus_display()), self.screen.title(self.xid))
        if self.pid is None:
            self.note = "The focused window does not report its process, so its accessibility tree cannot be matched."
            return
        if not self.screen.confined(self.pid):
            self.note = "The focused window's application also has windows on another display, so it is not read."
            return
        self.bus = get_bus(self.screen.bus_display())
        self.app = self.bus.application(self.pid)
        self.wine = None
        if self.app is None:
            prefix = wine_prefix(self.pid)
            if prefix is not None:
                self.wine = wine_elements(self, prefix)
                if self.wine is not None:
                    return
            self.bus.retry(self.screen.bus_display())
            self.note = "The focused window's application exposes no accessibility tree; use a screenshot."
            return
        self.tree = Tree(self.bus.Atspi)
        try:
            name = self.app.get_name()
        except Exception:
            name = ""
        if not self.window["app"] and name:
            self.window["app"] = name

    def roots(self):
        """(path, accessible, clip, origin) to read: open popups first, then the window."""
        frame, popups, rect = match_frame(self.tree, self.app, self.screen, self.xid, True)
        width, height = self.screen.size()
        screen_rect = {"x": 0, "y": 0, "width": width, "height": height}
        roots = [([index], top, screen_rect, origin) for index, top, _, origin in popups]
        if frame is not None:
            roots.append(([frame[0]], frame[1], rect or screen_rect, frame[2]))
        elif not roots:
            self.note = "The focused window was not found in its application's accessibility tree; use a screenshot."
        return roots


class Scale(float):
    """An element origin meaning: screen coordinates, divided by this scale."""


def element_id(xid, pid, path, fingerprint):
    return f"{xid:x}-{pid}-{'.'.join(str(i) for i in path)}-{fingerprint}"


ID_PATTERN = re.compile(r"([0-9a-f]{1,8})-(\d{1,9})-(\d{1,5}(?:\.\d{1,5}){0,63})-([0-9a-f]{6})")


def role_matches(role_name, wanted):
    if not wanted:
        return True
    wanted = " ".join(wanted.casefold().replace("-", " ").replace("_", " ").split())
    role_name = role_name.casefold()
    return role_name == wanted or wanted in role_name.split() or role_name.replace(" ", "") == wanted.replace(" ", "")


def collect(target, query=None, role=None):
    tree = target.tree
    found = []
    query = _norm(query) if query is not None else None

    def visit(node, path, node_role, states):
        if len(found) >= MAX_ELEMENTS:
            return False
        if query is None and (node_role == tree.Atspi.Role.SCROLL_PANE or node_role in tree.content_roles):
            box = tree.bounds(node, origin[0])
            if box is not None and intersects(box, clip[0]):
                if node_role == tree.Atspi.Role.SCROLL_PANE:
                    panes.append(clipped(box, clip[0]))
                elif tree.child_count(node) or node_role in tree.text_content_roles:
                    content.append(box)
        if query is None:
            wanted = tree.interesting(node, node_role, states)
            if wanted is False:
                return True
            name = tree.name(node, node_role, states)
            if wanted is None and not name:
                return True
        else:
            name = tree.name(node, node_role, states)
            if not name or query not in name.casefold():
                return True
            if node_role in tree.top_roles:
                return True
        role_name = tree.Atspi.role_get_name(node_role) or "unknown"
        if not role_matches(role_name, role):
            return True
        bounds = tree.bounds(node, origin[0])
        if bounds is None or not intersects(bounds, clip[0]):
            return True
        found.append({
            "id": element_id(target.xid, target.pid, path, tree.fingerprint(node_role, name)),
            "role": role_name, "name": name, "states": tree.state_names(states), "bounds": bounds,
        })
        # Expose capabilities rather than asking a policy to infer them from pixels.
        _, native_actions = tree.actions(node)
        supported = []
        if any(name in tree.press_actions for name in native_actions) or (node_role in tree.pointer_roles and tree.has(states, "SHOWING")) \
                or tree.has(states, "SELECTABLE"):
            supported.append("press")
        if tree.has(states, "EDITABLE"): supported.append("set-text")
        if tree.has(states, "FOCUSABLE"): supported.append("focus")
        found[-1]["actions"] = supported
        value = tree.value(node, node_role, states)
        if value is not None and value != "":
            found[-1]["value"] = value
        return True

    clip, origin = [None], [None]
    panes, content = [], []  # scroll panes; documents, texts and filled lists, readable as such
    for path, root, rect, at in target.roots():
        clip[0], origin[0] = rect, at
        tree.walk(root, path, visit)
        if len(found) >= MAX_ELEMENTS:
            break
    if query is None and len(found) < MAX_ELEMENTS:
        target.unread = unread_regions(panes, [e["bounds"] for e in found] + content)
    return found


UNREAD_AREA = 160 * 120  # smaller scrolled areas are not worth reading from pixels
UNREAD_COVER = 0.15  # the share of a scrolled area its exposed controls must cover


def clipped(box, clip):
    if clip is None:
        return box
    x, y = max(box["x"], clip["x"]), max(box["y"], clip["y"])
    right = min(box["x"] + box["width"], clip["x"] + clip["width"])
    bottom = min(box["y"] + box["height"], clip["y"] + clip["height"])
    return {"x": x, "y": y, "width": max(0, right - x), "height": max(0, bottom - y)}


def unread_regions(panes, boxes, limit=3):
    """Scrolled areas whose content the application draws but does not expose: a large
    scroll pane in which the exposed controls cover almost nothing (a list or icon view a
    toolkit leaves out of its tree, a custom canvas). Innermost first, at most `limit`, as
    [x, y, width, height] in seat coordinates."""
    def covered(pane):
        area = 0
        for box in boxes:
            part = clipped(box, pane)
            area += part["width"] * part["height"]
        return area / (pane["width"] * pane["height"])
    regions = []
    for pane in sorted(panes, key=lambda p: p["width"] * p["height"]):
        if pane["width"] * pane["height"] < UNREAD_AREA or covered(pane) >= UNREAD_COVER:
            continue
        if any(intersects(pane, r) for r in regions):
            continue
        regions.append(pane)
    return [[r["x"], r["y"], r["width"], r["height"]] for r in regions[:limit]]


EMBED = "\ufffc"  # AT-SPI's object replacement character: an embedded child in a text
SOFT = "\x00"  # a word break between pieces; becomes a space unless a newline is there


def read_text(target):
    """The window's text in reading order: each text's own characters, with each embedded
    object (a link inside a paragraph, a paragraph inside a page) expanded where it sits."""
    tree = target.tree
    Atspi = tree.Atspi
    total = [0]

    def embedded(node, own, children):
        """The child behind each EMBED in `own`, through Hypertext where offered."""
        try:
            hypertext = node.get_hypertext_iface() is not None
        except Exception:
            hypertext = False
        objects = [child for child in children if _role(child) != getattr(Atspi.Role, "STATIC", None)]
        result, next_object = [], 0
        for offset, char in enumerate(own):
            if char != EMBED:
                continue
            child = None
            if hypertext:
                try:
                    index = Atspi.Hypertext.get_link_index(node, offset)
                    if index >= 0:
                        child = Atspi.Hyperlink.get_object(Atspi.Hypertext.get_link(node, index), 0)
                except Exception:
                    child = None
            if child is None and next_object < len(objects):
                child = objects[next_object]
            next_object += 1
            result.append(child)
        return result

    def text_of(node, depth):
        if total[0] > MAX_TEXT or tree.exhausted() or depth > MAX_DEPTH:
            return ""
        tree.visited += 1
        states = tree.states(node)
        if states is None or (depth > 0 and not tree.has(states, "SHOWING")):
            return ""
        role = _role(node)
        children = [child for _, child in tree.children(node) if child is not None]
        own = tree.text(node)
        if own is not None and own.replace(EMBED, "").strip():
            # Real text: children are already in it, as characters or as EMBED marks.
            out = []
            objects = iter(embedded(node, own, children) if EMBED in own else [])
            for char in own:
                if char == EMBED:
                    child = next(objects, None)
                    out.append(piece(child, depth) if child is not None else "")
                else:
                    out.append(char)
            out = "".join(out)
        elif children:
            out = "".join(piece(child, depth) for child in children)
        else:
            # A control with no text of its own reads as its name; an empty field reads as nothing.
            labelled = (role in tree.actionable or role in tree.named_only) and role not in tree.value_roles
            out = tree.name(node, role, states) if labelled and not tree.has(states, "EDITABLE") else ""
        total[0] += len(out)
        return out

    def piece(child, depth):
        text = text_of(child, depth + 1)
        if not text:
            return ""
        return f"\n{text}\n" if _role(child) in tree.block_roles else f"{SOFT}{text}{SOFT}"

    pieces = [text_of(root, 0) for _, root, _, _ in reversed(target.roots())]
    text = "\n".join(pieces)
    text = re.sub(r"[ \t\x00]*\n[ \t\x00]*", "\n", text)
    text = re.sub(r" ?\x00+ ?", " ", text)  # one space where pieces meet, never two
    return re.sub(r"\n{3,}", "\n\n", text).strip()


def _role(node):
    try:
        return node.get_role()
    except Exception:
        return None


# --- Acting ----------------------------------------------------------------------------

def resolve(display_name, element):
    match = ID_PATTERN.fullmatch(element or "")
    if not match:
        raise Failure("element not found", NOT_FOUND)
    xid, pid = int(match.group(1), 16), int(match.group(2))
    path = [int(i) for i in match.group(3).split(".")]
    screen = make_screen(display_name)
    if xid not in screen.clients or not screen.confined(pid):
        raise Failure("element not found", NOT_FOUND)
    bus = get_bus(screen.bus_display())
    if (screen.pid(xid) or titled_pid(bus, screen.title(xid))) != pid:
        raise Failure("element not found", NOT_FOUND)
    app = bus.application(pid)
    if app is None:
        bus.retry(screen.bus_display())
        raise Failure("element not found", NOT_FOUND)
    tree = Tree(bus.Atspi)
    fingerprint = match.group(4)

    def at(path):
        node, top = app, None
        for index in path:
            try:
                node = node.get_child_at_index(index) if index < node.get_child_count() else None
            except Exception:
                node = None
            if node is None:
                return None, top
            top = top or node
        return node, top

    def matches(node):
        states = tree.states(node)
        try:
            role = node.get_role()
        except Exception:
            return None
        if states is None or tree.has(states, "DEFUNCT") or tree.fingerprint(role, tree.name(node, role, states)) != fingerprint:
            return None
        return states

    node, top = at(path)
    states = matches(node) if node is not None else None
    if states is None:
        # Its place moved (a sibling appeared or went, as a web page edits itself): the one
        # showing control of the window with the same role and name is the element.
        top, _ = at(path[:1])
        found = []
        if top is not None:
            tree.walk(top, path[:1], lambda n, p, role, st: found.append(n) if matches(n) is not None else None)
        if len(found) != 1:
            raise Failure("element not found", NOT_FOUND)
        node = found[0]
        states = matches(node)
    return screen, xid, tree, node, states, top_origin(screen, xid, pid, tree, top)


def wine_act(display_name, element, action, text):
    """An action on a control of a program under Wine; False when the id is not one."""
    match = ID_PATTERN.fullmatch(element or "")
    if not match:
        return False
    path = [int(i) for i in match.group(3).split(".")]
    if path[0] not in (WINE_CONTROL, WINE_MENU):
        return False
    xid, pid = int(match.group(1), 16), int(match.group(2))
    screen = make_screen(display_name)
    prefix = wine_prefix(pid)
    if xid not in screen.clients or screen.pid(xid) != pid or not screen.confined(pid) or prefix is None:
        raise Failure("element not found", NOT_FOUND)
    where = ("w." if path[0] == WINE_CONTROL else "m.") + ".".join(str(i) for i in path[1:])
    if action == "press":
        answer = wine_bridge(prefix, "press", screen.title(xid), where)
    elif action == "set-text":
        answer = wine_bridge(prefix, "set", screen.title(xid), where, text or "")
        if not answer or not answer.get("ok"):
            # A control that takes no text by message (Scintilla's custom editor): the seat's
            # pointer gives it focus and its keyboard replaces the text.
            class Window:
                pass
            target = Window()
            target.screen, target.xid, target.pid = screen, xid, pid
            element_here = None
            for _ in range(10):  # the window may be retitling as the text changes
                target.screen = make_screen(display_name)
                element_here = next((e for e in wine_elements(target, prefix) or [] if e["id"] == element), None)
                if element_here:
                    break
                time.sleep(0.1)
            bounds = (element_here or {}).get("bounds")
            if not bounds:
                raise Failure("the control takes no text and has no place on screen to type into")
            screen.activate(xid)
            screen.click(xid, bounds["x"] + min(bounds["width"] // 2, 40), bounds["y"] + min(bounds["height"] // 2, 20))
            time.sleep(0.1)
            screen.clear_text(xid)
            time.sleep(0.1)
            if text:
                screen.type_text(xid, text)
            return True
    else:
        raise Failure(f"{action} is not available on this control")
    if not answer or not answer.get("ok"):
        raise Failure((answer or {}).get("error") or "the program did not answer", NOT_FOUND if (answer or {}).get("error") == "element not found" else 1)
    return True


def act(display_name, element, action, text):
    if wine_act(display_name, element, action, text):
        return None
    screen, xid, tree, node, states, origin = resolve(display_name, element)
    if action == "press":
        if not (tree.has(states, "ENABLED") or tree.has(states, "SENSITIVE")):
            raise Failure("element is disabled")
        iface, names = tree.actions(node)
        try:
            opens_menu = node.get_role() in _roles(tree.Atspi, "MENU")
        except Exception:
            opens_menu = False
        bounds = tree.bounds(node, origin)
        # A menu's own action can open another menu of its bar (GTK 3 opens the first one), and
        # a menu left open that way does not yield to the next press: a menu on screen is
        # pressed with the seat's pointer at its own coordinates, like a person would.
        if opens_menu and bounds is not None and tree.has(states, "SHOWING"):
            screen.click(xid, bounds["x"] + bounds["width"] // 2, bounds["y"] + bounds["height"] // 2)
            return
        for wanted in tree.press_actions:
            if wanted in names:
                try:
                    if tree.Atspi.Action.do_action(iface, names.index(wanted)):
                        return
                except Exception:
                    pass
                break
        # An item of a list, table or tree without an action of its own is selected through its
        # container's Selection, as the toolkit selects it on a click.
        if select_in_parent(tree, node, states):
            return
        if bounds is None or not tree.has(states, "SHOWING"):
            raise Failure("element has no action and is not on screen")
        screen.click(xid, bounds["x"] + bounds["width"] // 2, bounds["y"] + bounds["height"] // 2)
        return
    if action == "focus":
        try:
            if node.get_component_iface() is not None and tree.Atspi.Component.grab_focus(node):
                return
        except Exception:
            pass
        # Toolkits without GrabFocus (GTK 4): an editable field on screen takes focus from the
        # seat's pointer, which only places the caret; anything else is not clicked.
        bounds = tree.bounds(node, origin)
        if tree.has(states, "EDITABLE") and bounds is not None and tree.has(states, "SHOWING"):
            screen.activate(xid)
            screen.click(xid, bounds["x"] + bounds["width"] // 2, bounds["y"] + bounds["height"] // 2)
            deadline = time.monotonic() + 0.4
            while time.monotonic() < deadline:
                if tree.has(tree.fresh_states(node), "FOCUSED"):
                    return
                screen.let_draw()
                time.sleep(0.01)
        raise Failure("element cannot take focus")
    if action == "set-text":
        if text is None:
            raise Failure("set-text needs --text", 2)
        # The toolkit's EditableText, when the field then reads the new text: some accept the
        # call and change nothing (Firefox's web fields).
        # A number for a numeric control (spin button, slider) goes in through its Value, which
        # the toolkit applies at once; typed digits wait for Enter or a focus change.
        try:
            number = float(text)
        except ValueError:
            number = None
        if number is not None and node.get_role() in _roles(tree.Atspi, "SPIN_BUTTON", "SLIDER") and node.get_value_iface() is not None:
            try:
                if tree.Atspi.Value.set_current_value(node, number):
                    return
            except Exception:
                pass
        pid = screen.pid(xid)
        try:
            if pid not in INERT_EDITABLE and node.get_editable_text_iface() is not None and tree.Atspi.EditableText.set_text_contents(node, text):
                # A password field reads back masked (bullets of the same length) or not at all.
                if node.get_role() in _roles(tree.Atspi, "PASSWORD_TEXT"):
                    return
                masked = lambda value: value is not None and len(value) == len(text) and text and set(value) <= set("•●*·")
                shown = wait_text(screen, tree, node, lambda value: value == text or masked(value), 0.3)
                if shown in (text, None) or masked(shown):
                    return
                INERT_EDITABLE.add(pid)  # remembered for the life of this helper
        except Exception:
            pass
        # Otherwise (Chromium's and Electron's fields have no EditableText): focus its window
        # and the field through AT-SPI, or with the seat's pointer at the field when that does
        # not take, then replace the text with keys sent to that window.
        if not tree.has(states, "EDITABLE"):
            raise Failure("element is not editable")
        screen.activate(xid)
        bounds = tree.bounds(node, origin)
        on_screen = bounds is not None and tree.has(states, "SHOWING")

        def grab():
            try:
                return node.get_component_iface() is not None and tree.Atspi.Component.grab_focus(node)
            except Exception:
                return False

        def click():
            if not on_screen:
                return False
            screen.click(xid, bounds["x"] + bounds["width"] // 2, bounds["y"] + bounds["height"] // 2)
            return True

        def focused(seconds):
            # States are cached per process until an event says otherwise: read them fresh.
            deadline = time.monotonic() + seconds
            while not tree.has(tree.fresh_states(node), "FOCUSED"):
                if time.monotonic() >= deadline:
                    return False
                screen.let_draw()
                time.sleep(0.01)
            return True

        if not (grab() and focused(0.4)) and not (click() and focused(0.4)):
            raise Failure("element did not take focus to type into")
        # Keys and typed text reach an application by different paths (key events; an input
        # method's commit), which it may handle out of order: the text goes in only once the
        # field reads empty, and the action ends once it reads the new text. An empty field
        # is not cleared: its Ctrl+A and BackSpace would have nothing to wait for.
        if wait_text(screen, tree, node, lambda value: True, 0) != "":
            screen.clear_text(xid)
            if wait_text(screen, tree, node, lambda value: not value, 0.5) is None:
                time.sleep(0.15)  # nothing to read: give the keys their time
        if text:
            screen.type_text(xid, text)
            shown = wait_text(screen, tree, node, lambda value: value == text, 1.0)
            if shown == "":
                # Some applications update what they expose well after the field itself.
                return "typed; the field does not read the new text yet"
            if shown is not None and shown != text:
                raise Failure(f"the field shows {shown[:80]!r} after typing; read it again before retrying")
        return
    raise Failure(f"unknown action {action}", 2)


def select_in_parent(tree, node, states):
    """Select `node` through the Selection of the nearest container that has one (its list or
    table; GTK 4 puts a row between a list and its cells): the container's child that holds
    `node` is selected. Whether `node` then reads selected."""
    if not tree.has(states, "SELECTABLE"):
        return False
    try:
        child, parent = node, node.get_parent()
        for _ in range(3):
            if parent is None:
                return False
            if parent.get_selection_iface() is not None:
                if not tree.Atspi.Selection.select_child(parent, child.get_index_in_parent()):
                    return False
                break
            child, parent = parent, parent.get_parent()
        else:
            return False
    except Exception:
        return False
    deadline = time.monotonic() + 0.3
    while not tree.has(tree.fresh_states(node), "SELECTED"):
        if time.monotonic() >= deadline:
            return False
        time.sleep(0.02)
    return True


# Processes whose EditableText accepts a new text and changes nothing (Firefox's web fields).
INERT_EDITABLE = set()


def wait_text(screen, tree, node, done, seconds):
    """Poll an element's text, read fresh, until `done(text)` or `seconds` pass; the last text,
    or None for an element without readable text. The seat lets applications draw meanwhile."""
    deadline = time.monotonic() + seconds
    while True:
        if seconds:
            screen.let_draw()
        try:
            node.clear_cache()
        except Exception:
            pass
        value = tree.text(node)
        if value is None or done(value) or time.monotonic() >= deadline:
            return value
        time.sleep(0.01)


# --- Commands --------------------------------------------------------------------------

def root_a11y_bus(display):
    address = (display.string(display.root, "AT_SPI_BUS") or "").strip("\0").strip()
    return address if address and _alive(address) else None


def launch_display_bus(display_name):
    """Start a session bus that knows this display, for at-spi-bus-launcher to run on.

    It exits with the X server (--exit-with-x11). Returns its address, or None."""
    env = {key: os.environ[key] for key in ("PATH", "HOME", "USER", "LOGNAME", "LANG", "XAUTHORITY")
           if key in os.environ}
    env["DISPLAY"] = display_name
    try:
        result = subprocess.run(["dbus-launch", "--sh-syntax", "--close-stderr", "--exit-with-x11"], env=env,
                                capture_output=True, text=True, timeout=20, start_new_session=True)
    except (OSError, subprocess.SubprocessError):
        return None
    match = re.search(r"DBUS_SESSION_BUS_ADDRESS='([^']+)'", result.stdout)
    return match.group(1) if match else None


def command_bus(display_name, wait):
    """Find this display's accessibility bus, starting one that is tied to it if need be.

    The goal is the AT_SPI_BUS property on the display's root window: every toolkit reads it
    before its session bus, so once it is set all applications on the display share that bus,
    whatever session bus they were started with. at-spi-bus-launcher sets it when it is
    started by a session bus that has the display in its environment: one recorded on the
    display, the X11 autolaunch bus, or failing those one started here for the display."""
    deadline = time.monotonic() + max(0.0, wait)
    launched = None
    session = os.environ.get("DBUS_SESSION_BUS_ADDRESS")
    if os.environ.get("CABOOSE_DISPLAY_CONTROL") and session:
        return seat_bus(display_name, session, deadline)

    def settle(display):
        for _ in range(20):
            address = root_a11y_bus(display)
            if address:
                return address
            time.sleep(0.25)
        return None

    while True:
        display = None
        try:
            display = Display(display_name)
            address = root_a11y_bus(display)
            if address:
                return {"address": address, "source": "AT_SPI_BUS"}
            for label, session in display_session_buses(display):
                if _a11y_of_session(session) and settle(display):
                    return {"address": root_a11y_bus(display), "source": label}
            if launched is None:
                launched = launch_display_bus(display_name) or ""
                a11y = _a11y_of_session(launched) if launched else None
                if a11y:
                    address = settle(display)
                    if address:
                        return {"address": address, "source": "display session bus"}
                    return {"address": a11y, "source": "display session bus",
                            "note": "AT_SPI_BUS was not set on the display, so applications may use another bus."}
        except Failure:
            pass
        finally:
            if display is not None:
                display.close()
        if time.monotonic() >= deadline:
            raise Failure(f"no accessibility bus could be started for display {display_name}")
        time.sleep(0.5)


def seat_bus(display_name, session, deadline):
    """A Caboose Display seat's accessibility bus: its session bus's. Wayland applications
    find it through the session bus; it is published as AT_SPI_BUS on the seat's Xwayland
    too, so X11 applications on the seat join the same bus."""
    # at-spi-bus-launcher names its socket after DISPLAY (bus_110, bus_101): without it, the
    # seats' launchers would share one path and the second would take the first's socket.
    # It is started by the session bus on first use, with that bus's activation environment.
    _activation_environment(session, {key: os.environ[key] for key in ("DISPLAY", "XAUTHORITY", "XDG_RUNTIME_DIR")
                                       if os.environ.get(key)})
    while True:
        address = _a11y_of_session(session)
        if address and _alive(address):
            break
        if time.monotonic() >= deadline:
            raise Failure("the seat's session bus has no accessibility bus")
        time.sleep(0.5)
    display = None
    try:
        display = Display(display_name)
        if root_a11y_bus(display) != address:
            env = dict(os.environ, DISPLAY=display_name)
            subprocess.run(["xprop", "-root", "-f", "AT_SPI_BUS", "8s", "-set", "AT_SPI_BUS", address], env=env,
                           check=True, timeout=10, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    except (Failure, OSError, subprocess.SubprocessError):
        return {"address": address, "source": "session bus",
                "note": "AT_SPI_BUS could not be set on the seat's Xwayland, so X11 applications may use another bus."}
    finally:
        if display is not None:
            display.close()
    return {"address": address, "source": "session bus"}


VALUE_OPTIONS = {"--display", "--query", "--role", "--element", "--action", "--text", "--wait"}


class Parser(argparse.ArgumentParser):
    def error(self, message):
        emit({"error": message}, 2)


def main(argv):
    if not os.environ.get("HOME"):  # Xlib finds ~/.Xauthority through it
        os.environ["HOME"] = pwd.getpwuid(os.getuid()).pw_dir
    os.environ.setdefault("PATH", "/usr/local/bin:/usr/bin:/bin")
    global CALLER_BUS
    if "CABOOSE_A11Y_BUS_STATE" not in os.environ:
        CALLER_BUS = os.environ.get("AT_SPI_BUS_ADDRESS") or None
    parser = Parser(prog="a11y.py", description="Read and act on a display's focused window through AT-SPI.")
    commands = parser.add_subparsers(dest="command", required=True, parser_class=Parser)
    for name in ("elements", "text", "bus", "serve"):
        sub = commands.add_parser(name)
        sub.add_argument("--display", required=True)
        if name == "bus":
            sub.add_argument("--wait", type=float, default=0.0)
    find = commands.add_parser("find")
    find.add_argument("--display", required=True)
    find.add_argument("--query", required=True)
    find.add_argument("--role")
    action = commands.add_parser("act")
    action.add_argument("--display", required=True)
    action.add_argument("--element", required=True)
    action.add_argument("--action", required=True, choices=["press", "focus", "set-text"])
    action.add_argument("--text")
    # "--text -5" and "--element --x" are values, not options: bind each value to its option
    # before argparse sees it, so callers may pass either "--opt value" or "--opt=value".
    joined, index = [], 0
    while index < len(argv):
        if argv[index] in VALUE_OPTIONS and index + 1 < len(argv):
            joined.append(f"{argv[index]}={argv[index + 1]}")
            index += 2
        else:
            joined.append(argv[index])
            index += 1
    args = parser.parse_args(joined)
    if args.command == "serve":
        serve(args.display)
        return
    result, code = execute(args)
    emit(result, code)


def dispatch_accessibility_events(context, limit=256):
    """Refresh libatspi's event-maintained cache without blocking for future events."""
    for _ in range(limit):
        if not context.pending():
            break
        context.iteration(False)


def serve(display):
    global SERVING, ACTIVE_ARGS
    SERVING = True
    import faulthandler
    for line in sys.stdin:
        try:
            request = json.loads(line)
            op = request.pop("op")
            if op not in ("elements", "find", "act", "text") or request.get("display", display) != display:
                raise ValueError("invalid worker request")
            ACTIVE_ARGS = argparse.Namespace(command=op, display=display, query=request.get("query"),
                role=request.get("role"), element=request.get("element"), action=request.get("action"), text=request.get("text"))
            if WARM_BUS is not None:
                _, GLib = _gio()
                dispatch_accessibility_events(GLib.MainContext.default())
            if needs_registration(op, request):
                refresh()
            # A native accessibility call can stall outside our tree-walk budget.
            # Capture its stack before the parent terminates the bounded request.
            faulthandler.dump_traceback_later(10)
            try:
                result, _ = execute(ACTIVE_ARGS)
                if stale(op, result):
                    refresh()
                    result, _ = execute(ACTIVE_ARGS)
            finally:
                faulthandler.cancel_dump_traceback_later()
        except ServedResult as result_error:
            result = result_error.result
        except Exception as error:
            result = {"error": str(error)}
        sys.stdout.write(json.dumps(result, ensure_ascii=False) + "\n")
        sys.stdout.flush()


def refresh():
    """Read the registry's applications and their top-level windows afresh. libatspi's cache
    learns of a new top-level (a dialog) from events that can lag behind and does not recover
    by itself; clearing the cached children of the desktop and of each application makes the
    next read ask the applications. The helper stays the same AT-SPI client: a new one would
    cost each GTK 3 application three descriptors (see `BusWorker`)."""
    global KNOWN_WINDOWS
    bus = WARM_BUS
    if bus is not None and bus.address:
        _, GLib = _gio()
        dispatch_accessibility_events(GLib.MainContext.default())
        try:
            bus.desktop.clear_cache_single()
            for index in range(bus.desktop.get_child_count()):
                app = bus.desktop.get_child_at_index(index)
                if app is not None:
                    app.clear_cache_single()
        except Exception:
            pass
    KNOWN_WINDOWS = seat_windows()


def stale(op, result):
    """Whether a long-lived helper's answer comes from a cache that missed a new window."""
    if op in ("elements", "find", "text"):
        return str(result.get("note", "")).startswith("The focused window was not found")
    return op == "act" and result.get("error") == "element not found"


def stale(op, result):
    """Whether a long-lived helper's answer comes from a cache that missed a new window."""
    if op in ("elements", "find", "text"):
        return str(result.get("note", "")).startswith("The focused window was not found")
    return op == "act" and result.get("error") == "element not found"


def reconnect():
    """Drop this helper's libatspi connection and cache; the next request registers again."""
    global WARM_BUS
    if WARM_BUS is not None and WARM_BUS.address:
        try:
            WARM_BUS.Atspi.exit()
        except Exception:
            pass
    WARM_BUS = None


def execute(args):
    is_act = args.command == "act"
    try:
        display_number(args.display)
        os.environ["DISPLAY"] = args.display
        if args.command == "bus":
            return command_bus(args.display, args.wait), 0
        if is_act:
            note = act(args.display, args.element, args.action, args.text)
            return {"ok": True, **({"note": note} if note else {})}, 0
        target = Target(args.display)
        result = {"window": target.window}
        if target.app is not None:
            try:
                result["toolkit"] = f"{target.app.get_toolkit_name() or ''} {target.app.get_toolkit_version() or ''}".strip()
            except Exception:
                pass
        if args.command == "text":
            if getattr(target, "wine", None) is not None:
                result["text"] = "\n".join(e.get("value") or e["name"] for e in target.wine if e.get("value") or e["name"])
            else:
                result["text"] = read_text(target) if target.app is not None else ""
            if len(result["text"]) > MAX_TEXT:
                result["text"] = result["text"][:MAX_TEXT]
                result["truncated"] = True
        else:
            query = args.query if args.command == "find" else None
            role = args.role if args.command == "find" else None
            if getattr(target, "wine", None) is not None:
                q = _norm(query) if query is not None else None
                result["elements"] = [e for e in target.wine if (q is None or q in _norm(e["name"])) and role_matches(e["role"], role)]
            else:
                result["elements"] = collect(target, query, role) if target.app is not None else []
            if getattr(target, "unread", None):
                result["unread"] = target.unread
            if target.app is not None and target.tree.partial:
                result["partial"] = (f"{len(target.tree.partial)} large container(s) ({', '.join(str(c) for c in target.tree.partial[:3])} children) "
                                     "are read in part: their selected children and the first few")
        if target.note:
            result["note"] = target.note
        return result, 0
    except Failure as failure:
        message = str(failure)
        return ({"ok": False, "error": message} if is_act else {"error": message}), failure.code
    except (SystemExit, ServedResult):
        raise
    except Exception as error:  # an unexpected library failure still answers in JSON
        message = f"{type(error).__name__}: {error}"
        return ({"ok": False, "error": message} if is_act else {"error": message}), 1


if __name__ == "__main__":
    main(sys.argv[1:])
