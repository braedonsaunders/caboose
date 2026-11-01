#!/usr/bin/env python3
"""The focused window's touch targets from its accessibility tree.

    caboose-targets.py serve
        For caboose-display, which runs it while a client aims touches (docs/display.md,
        "Touch targets"). Prints a JSON line whenever the focused window's targets change:
            {"window": ID, "targets": [[x, y, w, h, kind], ...]}
        and reads lines from caboose-display: "input ID" after the client's input to
        window ID, which is when most controls change.
    caboose-targets.py snapshot [--method walk|collection] [--repeat N]
        One reading as a JSON line, with "ms" (how long it took) and "nodes" (how many
        accessibility objects it visited).

Rectangles are in the seat's logical pixels. `kind` is a role class, with 0x80 set for a
disabled control:

    1 button   2 toggle (check, radio, switch)   3 link   4 menu item   5 tab
    6 text field   7 item (list, tree, table cell)   8 adjustable (slider, spin, scroll bar)
    9 window control the application draws itself (minimize, maximize, close)

Caboose draws every window's controls; toolkits are asked to draw none (an empty button
layout). An application that draws them in its own page (Electron apps with HTML title
bars, such as Obsidian) still lists them: named Minimize, Maximize, Restore or Close, in a
row against the window's top-left or top-right corner. The client hides and ignores those.

It runs as the desktop user with the seat's launch environment and reads the seat the way
a11y.py, next to it, does: Wayland and X11 windows alike, an application only while all its
windows are on this seat.
"""

import argparse
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import a11y  # noqa: E402

BUTTON, TOGGLE, LINK, MENU, TAB, FIELD, ITEM, ADJUST, CAPTION = range(1, 10)
DISABLED = 0x80
MAX_TARGETS = 1024

KINDS = {
    BUTTON: ("PUSH_BUTTON", "PUSH_BUTTON_MENU", "COMBO_BOX", "ICON", "IMAGE_MAP"),
    TOGGLE: ("TOGGLE_BUTTON", "CHECK_BOX", "RADIO_BUTTON", "SWITCH"),
    LINK: ("LINK",),
    MENU: ("MENU_ITEM", "CHECK_MENU_ITEM", "RADIO_MENU_ITEM", "MENU", "TEAROFF_MENU_ITEM"),
    TAB: ("PAGE_TAB",),
    FIELD: ("ENTRY", "PASSWORD_TEXT", "AUTOCOMPLETE", "EDITBAR", "TERMINAL"),
    ITEM: ("LIST_ITEM", "TREE_ITEM", "TABLE_CELL", "TABLE_COLUMN_HEADER", "COLUMN_HEADER"),
    ADJUST: ("SLIDER", "SPIN_BUTTON", "SCROLL_BAR", "DIAL"),
}

# After input, the controls are read again this long after it, in seconds: once the
# application has answered, and once more after a typical opening animation.
AFTER_INPUT = (0.12, 0.45)
# Accessibility events (a window activated, a menu shown) are read after this pause.
AFTER_EVENT = 0.08
# Readings are at least this far apart, and at least twice as far apart as the last one
# took, so a busy page never keeps the reader busy.
MIN_GAP = 0.15
# Changes no event announces (a scrolled page) are caught by reading this often.
POLL = 2.0
EVENTS = ("window:activate", "window:create", "window:destroy", "object:state-changed:showing",
          "object:children-changed")


# Window controls an application draws: the first word of their name, the band below the
# window's top edge they lie in, their size range, how far apart neighbours may be and how
# close the row must come to the window's side (logical pixels).
CAPTION_WORDS = ("minimize", "minimise", "maximize", "maximise", "unmaximize", "restore", "close")
CAPTION_BAND = 64
CAPTION_SIZE = (12, 96)
CAPTION_GAP = 12
CAPTION_EDGE = 12
CAPTION_VISITS = 4000


def is_caption_name(name):
    words = " ".join((name or "").split()).casefold().split(" ")
    return bool(words) and words[0] in CAPTION_WORDS


def caption_row(candidates, window):
    """The candidates (dicts with x, y, width, height and name) that are a window's own
    controls: a row of neighbours, one of them Close, against the window's top-left or
    top-right corner. `window` is the window's rectangle."""
    left, right = window["x"], window["x"] + window["width"]
    row = sorted(candidates, key=lambda c: c["x"])
    groups, group = [], []
    for c in row:
        if group and c["x"] - (group[-1]["x"] + group[-1]["width"]) > CAPTION_GAP:
            groups.append(group)
            group = []
        group.append(c)
    if group:
        groups.append(group)
    found = []
    for group in groups:
        start, end = group[0]["x"], max(c["x"] + c["width"] for c in group)
        against = start - left <= CAPTION_EDGE or right - end <= CAPTION_EDGE
        if against and any(" ".join(c["name"].split()).casefold().startswith("close") for c in group):
            found.extend(group)
    return found


def caption_controls(tree, root, origin, window):
    """The window controls an application drew in `root`, a window at `window`. Only the
    band below the window's top edge is visited."""
    band = window["y"] + CAPTION_BAND
    candidates = []
    stack = [root]
    visits = 0
    while stack and visits < CAPTION_VISITS:
        node = stack.pop()
        visits += 1
        states = tree.states(node)
        if states is None or (node is not root and not tree.has(states, "SHOWING")):
            continue
        bounds = tree.bounds(node, origin)
        if bounds is not None:
            if bounds["y"] >= band:
                continue
            try:
                name = node.get_name() or ""
            except Exception:
                name = ""
            low, high = CAPTION_SIZE
            if (is_caption_name(name) and bounds["y"] + bounds["height"] <= band
                    and low <= bounds["width"] <= high and low <= bounds["height"] <= high):
                _, actions = tree.actions(node)
                if any(action in tree.press_actions for action in actions):
                    candidates.append(dict(bounds, name=name))
                    continue
        for _, child in tree.children(node):
            if child is not None:
                stack.append(child)
    tree.visited += visits
    return caption_row(candidates, window)


def role_kinds(Atspi):
    found = {}
    for kind, names in KINDS.items():
        for name in names:
            role = getattr(Atspi.Role, name, None)
            if role is not None:
                found[role] = kind
    return found


def kind_of(tree, kinds, node, role, states):
    kind = kinds.get(role)
    if kind is None:
        if tree.has(states, "EDITABLE") and tree.has(states, "FOCUSABLE") and role in tree.editable_roles:
            kind = FIELD
        elif tree.has(states, "FOCUSABLE"):
            _, names = tree.actions(node)
            if any(name in tree.press_actions for name in names):
                kind = BUTTON
    if kind is None:
        return None
    if not (tree.has(states, "ENABLED") or tree.has(states, "SENSITIVE")):
        kind |= DISABLED
    return kind


class Reader:
    """Reads the focused window's targets, keeping the accessibility bus and the
    applications' confinement across readings."""

    def __init__(self, display):
        self.display = display
        self.bus = None
        self.confined = {}  # pid -> (when checked, confined)

    def is_confined(self, screen, pid):
        now = time.monotonic()
        checked = self.confined.get(pid)
        if checked is None or now - checked[0] > 10:
            checked = (now, screen.confined(pid))
            self.confined[pid] = checked
        return checked[1]

    def snapshot(self, method="walk"):
        started = time.monotonic()
        screen = a11y.make_screen(self.display)
        wid = screen.focused()
        result = {"window": wid, "targets": []}
        if not wid:
            return self.done(result, started)
        pid = screen.pid(wid)
        if pid is None or not self.is_confined(screen, pid):
            return self.done(result, started)
        if self.bus is None:
            self.bus = a11y.Bus(screen.bus_display())
        app = self.bus.application(pid)
        if app is None:
            return self.done(result, started)
        tree = a11y.Tree(self.bus.Atspi)
        kinds = role_kinds(tree.Atspi)
        frame, popups, rect = a11y.match_frame(tree, app, screen, wid, True)
        width, height = screen.size()
        whole = {"x": 0, "y": 0, "width": width, "height": height}
        roots = [(top, whole, origin) for _, top, _, origin in popups]
        if frame is not None:
            roots.append((frame[1], rect or whole, frame[2]))
        found = result["targets"]
        if frame is not None and rect:
            for c in caption_controls(tree, frame[1], frame[2], rect):
                found.append([c["x"], c["y"], c["width"], c["height"], CAPTION])

        def add(node, role, states, origin, clip):
            kind = kind_of(tree, kinds, node, role, states)
            if kind is None:
                return
            bounds = tree.bounds(node, origin)
            if bounds is None or not a11y.intersects(bounds, clip):
                return
            found.append([bounds["x"], bounds["y"], bounds["width"], bounds["height"], kind])

        for root, clip, origin in roots:
            if method == "collection" and collect_matches(tree, root, kinds, lambda n, r, s: add(n, r, s, origin, clip)):
                pass
            else:
                def visit(node, _path, role, states, origin=origin, clip=clip):
                    add(node, role, states, origin, clip)
                    return len(found) < MAX_TARGETS
                tree.walk(root, [], visit)
            if len(found) >= MAX_TARGETS:
                break
        result["nodes"] = tree.visited
        return self.done(result, started)

    @staticmethod
    def done(result, started):
        result["ms"] = round((time.monotonic() - started) * 1000, 1)
        return result


def collect_matches(tree, root, kinds, add):
    """One Collection call for every showing node of a target role, where the application
    implements Collection (the ATK bridge does, in the application's own process); False
    where it does not."""
    Atspi = tree.Atspi
    try:
        collection = root.get_collection_iface()
    except Exception:
        collection = None
    if collection is None:
        return False
    states = Atspi.StateSet.new([Atspi.StateType.SHOWING])
    rule = Atspi.MatchRule.new(states, Atspi.CollectionMatchType.ALL, None, Atspi.CollectionMatchType.NONE,
                               list(kinds.keys()), Atspi.CollectionMatchType.ANY, None,
                               Atspi.CollectionMatchType.NONE, False)
    try:
        matches = collection.get_matches(rule, Atspi.CollectionSortOrder.CANONICAL, MAX_TARGETS, True)
    except Exception:
        return False
    for node in matches:
        tree.visited += 1
        try:
            add(node, node.get_role(), node.get_state_set())
        except Exception:
            continue
    return True


class Server:
    """`serve`: reads when something has probably changed, prints what did."""

    def __init__(self, reader, method):
        import gi
        gi.require_version("GLib", "2.0")
        from gi.repository import GLib
        self.GLib = GLib
        self.reader = reader
        self.method = method
        self.last = None
        self.last_at = 0.0
        self.last_took = 0.0
        self.due = None  # monotonic time of the next reading
        self.timer = None
        self.listeners = []

    def run(self):
        GLib = self.GLib
        loop = GLib.MainLoop()
        channel = GLib.IOChannel.unix_new(sys.stdin.fileno())

        def on_input(source, condition):
            if condition & (GLib.IO_HUP | GLib.IO_ERR):
                loop.quit()
                return False
            line = sys.stdin.readline()
            if not line:
                loop.quit()
                return False
            if line.startswith("input"):
                for delay in AFTER_INPUT:
                    self.schedule(delay)
            return True

        GLib.io_add_watch(channel, GLib.PRIORITY_DEFAULT, GLib.IO_IN | GLib.IO_HUP | GLib.IO_ERR, on_input)
        GLib.timeout_add(int(POLL * 1000), lambda: (self.schedule(0), True)[1])
        self.schedule(0)
        loop.run()

    def listen(self):
        """Accessibility events; registered once the bus is known, after the first reading."""
        if self.listeners or self.reader.bus is None:
            return
        Atspi = self.reader.bus.Atspi
        listener = Atspi.EventListener.new(lambda _event: self.schedule(AFTER_EVENT))
        for name in EVENTS:
            try:
                listener.register(name)
            except Exception:
                continue
        self.listeners.append(listener)

    def schedule(self, delay):
        now = time.monotonic()
        at = max(now + delay, self.last_at + max(MIN_GAP, 2 * self.last_took))
        if self.due is not None and self.due <= at:
            return
        if self.timer is not None:
            self.GLib.source_remove(self.timer)
        self.due = at
        self.timer = self.GLib.timeout_add(max(0, int((at - now) * 1000)), self.fire)

    def fire(self):
        self.timer = None
        self.due = None
        started = time.monotonic()
        try:
            reading = self.reader.snapshot(self.method)
        except Exception as error:  # a vanished application, a bus that went away
            print(f"caboose-targets: {error}", file=sys.stderr, flush=True)
            reading = {"window": None, "targets": []}
        self.last_at = time.monotonic()
        self.last_took = self.last_at - started
        out = {"window": reading.get("window"), "targets": reading.get("targets") or []}
        if out["window"] and out != self.last:
            self.last = out
            sys.stdout.write(json.dumps(out, separators=(",", ":")) + "\n")
            sys.stdout.flush()
        self.listen()
        return False


def main(argv):
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="command", required=True)
    serve = commands.add_parser("serve")
    serve.add_argument("--display", default=os.environ.get("DISPLAY", ""))
    serve.add_argument("--method", choices=["walk", "collection"], default="collection")
    snap = commands.add_parser("snapshot")
    snap.add_argument("--display", default=os.environ.get("DISPLAY", ""))
    snap.add_argument("--method", choices=["walk", "collection"], default="collection")
    snap.add_argument("--repeat", type=int, default=1)
    args = parser.parse_args(argv)
    reader = Reader(args.display)
    if args.command == "serve":
        Server(reader, args.method).run()
        return
    for _ in range(args.repeat):
        print(json.dumps(reader.snapshot(args.method)), flush=True)


if __name__ == "__main__":
    main(sys.argv[1:])
