#!/usr/bin/env python3
"""Disposable GTK controls for specialist evaluation; contains only generated test data."""
import argparse
import json
import gi
gi.require_version('Gtk', '3.0')
from gi.repository import Gtk
p = argparse.ArgumentParser()
p.add_argument('--variant', choices=['development', 'heldout'], required=True)
p.add_argument('--log', required=True)
a = p.parse_args()
def log(kind, name, value):
    with open(a.log, 'a') as f:
        f.write(json.dumps(dict(kind=kind, name=name, value=value)) + '\n')
window = Gtk.Window(title='Specialist evaluation ' + a.variant)
window.set_default_size(500, 300)
box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12, margin=20)
window.add(box)
entry_name, toggle_name = ('Title', 'Enable alerts') if a.variant == 'development' else ('Destination', 'Keep receipt')
entry = Gtk.Entry()
entry.get_accessible().set_name(entry_name)
entry.connect('changed', lambda w: log('text', entry_name, w.get_text()))
toggle = Gtk.CheckButton(label=toggle_name)
toggle.connect('toggled', lambda w: log('toggle', toggle_name, w.get_active()))
distractor = Gtk.Button(label='Reset all')
distractor.connect('clicked', lambda _: log('wrong', 'Reset all', True))
widgets = [entry, toggle, distractor] if a.variant == 'development' else [distractor, toggle, entry]
for widget in widgets: box.pack_start(widget, False, False, 0)
window.connect('destroy', Gtk.main_quit)
window.show_all()
Gtk.main()
