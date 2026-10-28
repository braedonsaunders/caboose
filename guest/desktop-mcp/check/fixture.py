#!/usr/bin/env python3
"""A GTK 3 window with known controls, for check-a11y.sh.

    fixture.py --title T --log FILE [--dialog] [--also-display :N]

Shows a main window titled T with an "Open" button. With --dialog it also opens a
"Save changes?" dialog: a message, a "File name" entry, a "Keep a backup" check box and
"Cancel" / "Save" buttons. Every observable effect is appended to FILE, one line each:
"clicked <button>", "text <entry contents>", "toggled <state>". --also-display opens one
more window, on another X display, from the same process.
"""
import argparse

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import Gdk, Gtk  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--title", required=True)
parser.add_argument("--log", required=True)
parser.add_argument("--dialog", action="store_true")
parser.add_argument("--also-display")
args = parser.parse_args()


def log(line):
    with open(args.log, "a", encoding="utf-8") as handle:
        handle.write(line + "\n")


main = Gtk.Window(title=args.title)
main.set_default_size(480, 320)
main.move(40, 40)
box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8, margin=12)
box.pack_start(Gtk.Label(label=f"{args.title} is running."), False, False, 0)
open_button = Gtk.Button(label="Open")
open_button.connect("clicked", lambda _: log("clicked Open"))
box.pack_start(open_button, False, False, 0)
main.add(box)
main.connect("destroy", Gtk.main_quit)
main.show_all()

if args.dialog:
    dialog = Gtk.Dialog(title="Save changes?", transient_for=main)
    dialog.set_default_size(420, 220)
    dialog.move(120, 120)
    area = dialog.get_content_area()
    area.set_spacing(8)
    area.add(Gtk.Label(label="Save your changes to report.txt before closing?"))
    row = Gtk.Box(spacing=8)
    label = Gtk.Label(label="File name")
    entry = Gtk.Entry()
    entry.set_text("report.txt")
    label.set_mnemonic_widget(entry)
    entry.connect("changed", lambda widget: log(f"text {widget.get_text()}"))
    row.pack_start(label, False, False, 0)
    row.pack_start(entry, True, True, 0)
    area.add(row)
    backup = Gtk.CheckButton(label="Keep a backup")
    backup.connect("toggled", lambda widget: log(f"toggled {widget.get_active()}"))
    area.add(backup)
    cancel = dialog.add_button("Cancel", Gtk.ResponseType.CANCEL)
    save = dialog.add_button("Save", Gtk.ResponseType.OK)
    cancel.connect("clicked", lambda _: log("clicked Cancel"))
    save.connect("clicked", lambda _: log("clicked Save"))
    dialog.connect("response", lambda *_: None)  # stay open: the check presses more than once
    dialog.show_all()

if args.also_display:
    other = Gdk.Display.open(args.also_display)
    elsewhere = Gtk.Window(title=f"{args.title} elsewhere")
    elsewhere.set_screen(other.get_default_screen())
    elsewhere.add(Gtk.Button(label="Elsewhere"))
    elsewhere.show_all()

log("ready")
Gtk.main()
