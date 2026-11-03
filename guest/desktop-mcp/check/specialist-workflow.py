#!/usr/bin/env python3
"""Generated real GTK forms for training/evaluation; never reads owner data."""
import argparse
import json
import signal
import gi
gi.require_version('Gtk', '3.0')
from gi.repository import Gtk, GLib
parser = argparse.ArgumentParser()
parser.add_argument('--cases', required=True)
parser.add_argument('--effects', required=True)
a = parser.parse_args()
cases = json.load(open(a.cases))
index = -1
window = None
box = None

def emit(event, **fields):
    with open(a.effects, 'a') as f:
        f.write(json.dumps(dict(case=index, event=event, **fields)) + '\n')

def advance(*_):
    global index, window, box
    if window is not None: window.destroy()
    index += 1
    if index >= len(cases):
        Gtk.main_quit()
        return False
    spec = cases[index]
    window = Gtk.Window(title=f'Specialist case {index}')
    window.set_default_size(560, 360)
    box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10, margin=20)
    window.add(box)
    entries = []
    rows = []
    for field in spec['fields']:
        entry = Gtk.Entry()
        entry.get_accessible().set_name(field['name'])
        entry.connect('changed', lambda w, name=field['name']: emit('edit', name=name, value=w.get_text()))
        entries.append(entry)
        rows.append(entry)
    toggle = Gtk.CheckButton(label=spec['toggle'])
    toggle.connect('toggled', lambda w: emit('toggle', value=w.get_active()))
    rows.append(toggle)
    submit = Gtk.Button(label=spec['submit'])
    def submit_clicked(_):
        ok = all(entry.get_text() == field['value'] for entry, field in zip(entries, spec['fields'])) and toggle.get_active()
        emit('submit', correct=ok)
        if ok: submit.set_label(spec['complete'])
    submit.connect('clicked', submit_clicked)
    distractor = Gtk.Button(label=spec['distractor'])
    distractor.connect('clicked', lambda _: emit('wrong_control'))
    rows += [submit, distractor]
    for i in spec['order']: box.pack_start(rows[i], False, False, 0)
    if spec.get('ambiguous'):
        for _ in range(2): box.pack_start(Gtk.Button(label=spec['complete']), False, False, 0)
    window.show_all()
    emit('ready')
    return False

def rearrange():
    if box is not None:
        for position, child in enumerate(box.get_children()[1:] + box.get_children()[:1]):
            box.reorder_child(child, position)
        emit('rearranged')
    return True
GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signal.SIGUSR2, rearrange)
GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signal.SIGUSR1, lambda: (advance(), True)[1])
advance()
Gtk.main()
