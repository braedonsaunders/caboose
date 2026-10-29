#!/usr/bin/env python3
"""Real GTK3 decoration regression. Run via dev.sh after cargo build.

Requires python3-gi and gir1.2-gtk-3.0. Only a private compositor is used.
Ordinary windows must have no GTK titlebar; an app's custom header and menus stay.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


def client(output, custom):
    import gi
    gi.require_version('Gtk', '3.0')
    from gi.repository import Gtk, GLib
    window = Gtk.Window(title='Decoration check')
    window.set_default_size(400, 240)
    box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
    menu = Gtk.MenuBar()
    menu.append(Gtk.MenuItem(label='File'))
    box.pack_start(menu, False, False, 0)
    box.pack_start(Gtk.Label(label='Content remains intact'), True, True, 0)
    window.add(box)
    header = None
    if custom:
        header = Gtk.HeaderBar(title='App actions')
        header.pack_start(Gtk.Button(label='Save'))
        window.set_titlebar(header)
    window.show_all()

    def inspect():
        defaults = []
        def visit(widget):
            if widget.get_style_context().has_class('default-decoration'):
                defaults.append(widget.get_visible())
            if isinstance(widget, Gtk.Container):
                widget.forall(visit)
        visit(window)
        Path(output).write_text(json.dumps({
            'automatic_titlebar': any(defaults),
            'menu_visible': menu.get_mapped() and menu.get_allocated_height() > 0,
            'custom_header': header is not None and header.get_mapped(),
        }))
        window.destroy()
        Gtk.main_quit()
        return False
    GLib.timeout_add(500, inspect)
    Gtk.main()


def main():
    if len(sys.argv) > 1:
        client(sys.argv[1], sys.argv[2] == 'custom')
        return
    binary = Path(os.environ.get('CABOOSE_DISPLAY_BIN', Path(__file__).resolve().parent.parent / 'target/debug')) / 'caboose-display'
    with tempfile.TemporaryDirectory(prefix='caboose-decoration-') as directory:
        root = Path(directory)
        token = root / 'token'
        token.write_text('private-decoration-test')
        for backend in ('wayland', 'x11'):
            for custom in (False, True):
                output = root / 'result.json'
                output.unlink(missing_ok=True)
                env = dict(os.environ, XDG_RUNTIME_DIR=directory)
                command = [str(binary), '--listen', '127.0.0.1:0', '--no-audio', '--token-file', str(token),
                           '--', 'env', 'GDK_BACKEND=' + backend, sys.executable, str(Path(__file__).resolve()),
                           str(output), 'custom' if custom else 'default']
                proc = subprocess.Popen(command, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
                try:
                    import time
                    deadline = time.monotonic() + 15
                    while not output.exists() and proc.poll() is None and time.monotonic() < deadline:
                        time.sleep(.1)
                finally:
                    proc.terminate()
                    try:
                        _, errors = proc.communicate(timeout=5)
                    except subprocess.TimeoutExpired:
                        proc.kill()
                        _, errors = proc.communicate()
                assert output.exists(), errors.decode(errors='replace')
                result = json.loads(output.read_text())
                assert not result['automatic_titlebar'], (backend, custom, result)
                assert result['menu_visible'], result
                assert result['custom_header'] == custom, result
                print(f'{backend} {"custom header" if custom else "ordinary window"}: PASS')


if __name__ == '__main__':
    main()
