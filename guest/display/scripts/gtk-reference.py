#!/usr/bin/env python3
"""A GTK 3 window that also draws itself offscreen, for gpu-windows-check.py.

    gtk-reference.py TITLE REFERENCE.png

Shows a fixed-size window of text titled TITLE and writes the same widgets, drawn by GTK
in an offscreen window of the same size, to REFERENCE.png: what the window's picture must
be, pixel for pixel. The size (300x161) is odd on purpose: rows that are not a multiple of
any block or alignment.
"""
import sys

import gi

gi.require_version('Gtk', '3.0')
from gi.repository import Gdk, GLib, Gtk  # noqa: E402

WIDTH, HEIGHT = 300, 161
LINES = ['Caboose GPU check', 'The quick brown fox', 'jumps over 0123456789', 'il1| O0o ;:,. {}[]']


def content():
    box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
    # An opaque background of its own: text is antialiased against the same pixels in the
    # window and offscreen (an offscreen window is otherwise transparent).
    box.set_name('gpu-check')
    for line in LINES:
        label = Gtk.Label(label=line, xalign=0)
        box.pack_start(label, False, False, 0)
    box.set_size_request(WIDTH, HEIGHT)
    return box


def main():
    title, reference = sys.argv[1], sys.argv[2]
    css = Gtk.CssProvider()
    css.load_from_data(b'#gpu-check { background-color: #f6f5f4; color: #202020; }')
    Gtk.StyleContext.add_provider_for_screen(Gdk.Screen.get_default(), css, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
    offscreen = Gtk.OffscreenWindow()
    offscreen.add(content())
    offscreen.show_all()

    window = Gtk.Window(title=title)
    window.set_resizable(False)
    window.add(content())
    window.connect('destroy', Gtk.main_quit)

    def save():
        pixbuf = offscreen.get_pixbuf()
        if pixbuf is None:
            return True
        pixbuf.savev(reference, 'png', [], [])
        window.show_all()
        return False

    GLib.timeout_add(300, save)
    Gtk.main()


if __name__ == '__main__':
    main()
