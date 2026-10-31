#!/usr/bin/env python3
"""A GTK 3 window dense with small mouse-sized controls, for the touch-targeting benchmark.

Prints JSON lines on stdout:

    {"truth": [{"name", "kind", "rect": [x, y, w, h]}], "size": [w, h]}
        once laid out: every control's rectangle in window-local logical pixels (the
        origin is the window's geometry origin, client-side shadows excluded)
    {"press": NAME | null, "at": [x, y]}
        for every button press: the control that received it, and where, window-local

The truth is the toolkit's own layout, independent of the accessibility tree.
"""

import json
import sys

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
from gi.repository import Gdk, GLib, Gtk  # noqa: E402

ICONS = ["document-new", "document-open", "document-save", "edit-cut", "edit-copy", "edit-paste",
         "edit-undo", "edit-redo", "edit-find", "zoom-in", "zoom-out", "view-refresh",
         "go-previous", "go-next", "go-up", "go-down"]

targets = []  # (name, kind, widget)


def emit(value):
    sys.stdout.write(json.dumps(value) + "\n")
    sys.stdout.flush()


def add(name, kind, widget):
    targets.append((name, kind, widget))
    return widget


def build(window):
    box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
    box.set_border_width(6)
    window.add(box)

    menubar = Gtk.MenuBar()
    for label in ["File", "Edit", "View", "Tools", "Help"]:
        item = add(f"menu-{label.lower()}", "menu", Gtk.MenuItem(label=label))
        menubar.append(item)
    box.pack_start(menubar, False, False, 0)

    toolbar = Gtk.Toolbar()
    toolbar.set_icon_size(Gtk.IconSize.SMALL_TOOLBAR)
    for icon in ICONS[:12]:
        button = Gtk.ToolButton()
        button.set_icon_name(icon)
        button.set_label(icon)
        button.set_tooltip_text(icon)
        toolbar.insert(button, -1)
        add(f"tool-{icon}", "button", button)
    box.pack_start(toolbar, False, False, 0)

    # Flat icon buttons with small gaps, as in a sidebar header or a status bar.
    row = Gtk.Box(spacing=2)
    for icon in ICONS:
        button = Gtk.Button.new_from_icon_name(icon, Gtk.IconSize.MENU)
        button.set_relief(Gtk.ReliefStyle.NONE)
        button.set_tooltip_text(f"flat {icon}")
        row.pack_start(add(f"flat-{icon}", "button", button), False, False, 0)
    box.pack_start(row, False, False, 0)

    grid = Gtk.Grid(column_spacing=12, row_spacing=0)
    for r in range(4):
        for c in range(6):
            check = Gtk.CheckButton(label=f"opt {r}{c}")
            grid.attach(add(f"check-{r}{c}", "toggle", check), c, r, 1, 1)
    box.pack_start(grid, False, False, 0)

    radios = Gtk.Box(spacing=8)
    group = None
    for i in range(8):
        radio = Gtk.RadioButton.new_with_label_from_widget(group, f"r{i}")
        group = group or radio
        radios.pack_start(add(f"radio-{i}", "toggle", radio), False, False, 0)
    box.pack_start(radios, False, False, 0)

    links = Gtk.Box(spacing=0)
    for word in ["home", "about", "docs", "faq", "blog", "terms", "privacy", "contact"]:
        link = Gtk.LinkButton.new_with_label(f"https://example.invalid/{word}", word)
        link.connect("activate-link", lambda *_: True)
        links.pack_start(add(f"link-{word}", "link", link), False, False, 0)
    box.pack_start(links, False, False, 0)

    fields = Gtk.Box(spacing=8)
    for i in range(3):
        spin = Gtk.SpinButton.new_with_range(0, 100, 1)
        fields.pack_start(add(f"spin-{i}", "field", spin), False, False, 0)
    combo = Gtk.ComboBoxText()
    for item in ["alpha", "beta", "gamma"]:
        combo.append_text(item)
    combo.set_active(0)
    fields.pack_start(add("combo", "button", combo), False, False, 0)
    entry = Gtk.Entry()
    entry.set_width_chars(12)
    fields.pack_start(add("entry", "field", entry), False, False, 0)
    scale = Gtk.Scale.new_with_range(Gtk.Orientation.HORIZONTAL, 0, 100, 1)
    scale.set_size_request(160, -1)
    fields.pack_start(add("scale", "slider", scale), False, False, 0)
    box.pack_start(fields, False, False, 0)

    # Tiny close buttons, as on tabs.
    tabs = Gtk.Box(spacing=10)
    for i in range(10):
        close = Gtk.Button.new_from_icon_name("window-close-symbolic", Gtk.IconSize.MENU)
        close.set_relief(Gtk.ReliefStyle.NONE)
        close.set_tooltip_text(f"close {i}")
        label = Gtk.Label(label=f"tab {i}")
        tabs.pack_start(label, False, False, 0)
        tabs.pack_start(add(f"close-{i}", "button", close), False, False, 0)
    box.pack_start(tabs, False, False, 0)

    store = Gtk.ListStore(bool, str, str)
    for i in range(8):
        store.append([i % 2 == 0, f"row {i}", f"{i * 37} KB"])
    view = Gtk.TreeView(model=store)
    toggle = Gtk.CellRendererToggle()
    view.append_column(Gtk.TreeViewColumn("On", toggle, active=0))
    view.append_column(Gtk.TreeViewColumn("Name", Gtk.CellRendererText(), text=1))
    view.append_column(Gtk.TreeViewColumn("Size", Gtk.CellRendererText(), text=2))
    box.pack_start(view, False, False, 0)

    # A button that shows and hides a row of buttons: a change the targets must follow.
    more = Gtk.Box(spacing=4)
    toggle = add("more", "button", Gtk.Button(label="More"))
    extra = Gtk.Box(spacing=4)
    for i in range(6):
        extra.pack_start(add(f"extra-{i}", "button", Gtk.Button(label=f"x{i}")), False, False, 0)
    extra.set_no_show_all(True)
    for child in extra.get_children():
        child.show()
    toggle.connect("clicked", lambda *_: extra.set_visible(not extra.get_visible()))
    more.pack_start(toggle, False, False, 0)
    more.pack_start(extra, False, False, 0)
    box.pack_start(more, False, False, 0)
    return view


def widget_rect(widget, top):
    alloc = widget.get_allocation()
    point = widget.translate_coordinates(top, 0, 0)
    if point is None:
        return None
    return [point[0], point[1], alloc.width, alloc.height]


def tree_rows(view, top):
    """Each row's cells as targets: the tree's rows are accessible table cells."""
    rows = []
    model = view.get_model()
    for i in range(len(model)):
        path = Gtk.TreePath.new_from_indices([i])
        for c, column in enumerate(view.get_columns()):
            area = view.get_cell_area(path, column)
            x, y = view.convert_bin_window_to_widget_coords(area.x, area.y)
            point = view.translate_coordinates(top, x, y)
            rows.append((f"cell-{i}-{c}", "toggle" if c == 0 else "item", [point[0], point[1], area.width, area.height]))
    return rows


def geometry_origin(window):
    """Where the window's geometry (its content, without client-side shadows) starts in its
    own coordinates: GTK 3's shadow margin on a client-side decorated window."""
    gdk_window = window.get_window()
    if gdk_window is None:
        return 0, 0
    frame = gdk_window.get_frame_extents()
    origin = gdk_window.get_origin()
    return max(0, origin[1] - frame.x), max(0, origin[2] - frame.y)


def main():
    window = Gtk.Window(title="Caboose targets GTK 3")
    window.set_default_size(980, 660)
    view = build(window)
    window.connect("destroy", Gtk.main_quit)
    names = {}

    def name_of(widget):
        while widget is not None:
            if widget in names:
                return names[widget]
            widget = widget.get_parent()
        return None

    def on_event(event):
        if event.type == Gdk.EventType.BUTTON_PRESS:
            widget = Gtk.get_event_widget(event)
            point = None
            name = name_of(widget)
            if widget is not None:
                ok, x, y = event.get_coords()
                if ok:
                    # Event coordinates are relative to the event's GdkWindow (buttons and
                    # the tree view have their own); both go through root coordinates.
                    at = event.window.get_root_coords(x, y)
                    origin = widget.get_toplevel().get_window().get_root_coords(0, 0)
                    point = [at[0] - origin[0], at[1] - origin[1]]
            if widget is view and point is not None:
                local = view.get_toplevel().translate_coordinates(view, int(point[0]), int(point[1]))
                if local is not None:
                    bin_point = view.convert_widget_to_bin_window_coords(*local)
                    hit = view.get_path_at_pos(*bin_point)
                    if hit is not None:
                        path, column, _, _ = hit
                        name = f"cell-{path.get_indices()[0]}-{view.get_columns().index(column)}"
            emit({"press": name, "at": point})
        Gtk.main_do_event(event)

    for name, _kind, widget in targets:
        names[widget] = name

    def report():
        top = window
        truth = []
        for name, kind, widget in targets:
            if not widget.get_mapped():
                continue
            rect = widget_rect(widget, top)
            if rect and rect[2] > 0 and rect[3] > 0:
                truth.append({"name": name, "kind": kind, "rect": rect})
        for name, kind, rect in tree_rows(view, top):
            truth.append({"name": name, "kind": kind, "rect": rect})
        alloc = window.get_allocation()
        emit({"truth": truth, "size": [alloc.width, alloc.height], "origin": list(geometry_origin(window))})
        return False

    Gdk.event_handler_set(on_event)
    window.show_all()
    GLib.timeout_add(1500, report)
    Gtk.main()


if __name__ == "__main__":
    main()
