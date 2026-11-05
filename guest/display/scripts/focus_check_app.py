#!/usr/bin/env python3
"""A GTK 3 window for check-focus.sh: an entry whose text is written to OUT on every change.

F2 opens a dialog transient for the window that closes itself after a second; the entry's
own context menu (a right click) is a popup with a keyboard grab. Both leave the keyboard
to the compositor to give back.

    focus_check_app.py OUT
"""
import sys

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import GLib, Gdk, Gtk  # noqa: E402

out = sys.argv[1]
window = Gtk.Window(title="focus-check")
window.set_default_size(480, 160)
entry = Gtk.Entry()
window.add(entry)


def changed(_entry):
    with open(out, "w") as f:
        f.write(entry.get_text())


def dialog():
    d = Gtk.Dialog(title="focus-check-dialog", transient_for=window, modal=True)
    d.add_button("OK", Gtk.ResponseType.OK)
    d.show_all()
    GLib.timeout_add(1000, lambda: (d.destroy(), False)[1])


def key(_window, event):
    if event.keyval == Gdk.KEY_F2:
        dialog()
        return True
    return False


entry.connect("changed", changed)
window.connect("key-press-event", key)
window.connect("destroy", Gtk.main_quit)
window.show_all()
Gtk.main()
