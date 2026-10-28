"""List and launch desktop entries using the guest's own desktop environment."""
import configparser
import json
import os
import pathlib
import shutil
import sys

ROOTS = [pathlib.Path.home() / '.local/share/applications', pathlib.Path('/usr/local/share/applications'), pathlib.Path('/usr/share/applications')]

def entries():
    found = {}
    for root in ROOTS:
        if not root.exists():
            continue
        for path in sorted(root.rglob('*.desktop')):
            ident = str(path.relative_to(root)).replace('/', '-')
            if ident in found:
                continue
            # Record hidden overrides, too, so a lower-priority entry stays hidden.
            found[ident] = path
    return found

def read(path):
    parser = configparser.ConfigParser(interpolation=None, strict=False)
    parser.optionxform = str
    try:
        parser.read(path, encoding='utf-8')
        section = parser['Desktop Entry']
        if section.get('Type') != 'Application' or section.getboolean('Hidden', fallback=False) or section.getboolean('NoDisplay', fallback=False):
            return None
        if section.get('TryExec') and not shutil.which(section['TryExec']):
            return None
        if not section.get('Name') or not section.get('Exec'):
            return None
        return section
    except (OSError, ValueError, KeyError, configparser.Error):
        return None

if sys.argv[1] == 'launch':
    if os.environ.get('CABOOSE_GPU') == 'wsl':
        os.environ.setdefault('GALLIUM_DRIVER', 'd3d12')
    # Craft's winit GUI must use X11, including Caboose Display's Xwayland DISPLAY.
    # Keep the driver's DISPLAY and XAUTHORITY; only remove Wayland selection hints.
    craft = {'photocraft', 'lightcraft', 'filmcraft', 'vectorcraft', 'pdfcraft',
             'effectcraft', 'designcraft', 'wordcraft', 'gridcraft', 'deckcraft',
             'cadcraft', 'soundcraft', 'figcraft'}
    if sys.argv[2] in {f'ai.storyteller.{name}.desktop' for name in craft}:
        os.environ.pop('WAYLAND_DISPLAY', None)
        os.environ['XDG_SESSION_TYPE'] = 'x11'
        os.environ['WINIT_UNIX_BACKEND'] = 'x11'
        os.environ['GDK_BACKEND'] = 'x11'
        os.environ['QT_QPA_PLATFORM'] = 'xcb'
    entry = entries().get(sys.argv[2])
    if not entry or read(entry) is None:
        raise SystemExit('Application not found')
    # GLib handles desktop field codes and does not interpret the Exec as shell; this is
    # what `gio launch` does, without needing the CLI (libglib2.0-bin) in the image.
    import gi
    gi.require_version('Gio', '2.0')
    from gi.repository import Gio
    info = Gio.DesktopAppInfo.new_from_filename(str(entry))
    if info is None:
        raise SystemExit('Application could not be started')
    # The app inherits this process's stdio. Left as the exec pipes, they stay open for the
    # app's lifetime and the host waits out its timeout before the launch returns.
    devnull = os.open(os.devnull, os.O_RDWR)
    saved = os.dup(2)
    for fd in (0, 1, 2):
        os.dup2(devnull, fd)
    try:
        files = []
        if len(sys.argv) > 3:
            relative = sys.argv[3]
            if not relative or relative.startswith('/') or any(part in ('', '.', '..') for part in relative.split('/')) or '\0' in relative:
                raise ValueError('Invalid file path')
            files = [Gio.File.new_for_path(str(pathlib.Path.home() / relative))]
        launched = info.launch(files, None)
    finally:
        os.dup2(saved, 2)
    if not launched:
        raise SystemExit('Application could not be started')
else:
    import gi
    gi.require_version('Gtk', '3.0')
    from gi.repository import Gtk
    import base64
    theme = Gtk.IconTheme.get_default()
    if theme is None:
        raise SystemExit(f"No GTK icon theme available on display {os.environ.get('WAYLAND_DISPLAY') or os.environ.get('DISPLAY', ':100')}")
    apps = []
    start = int(sys.argv[2])
    for ident, path in entries().items():
        section = read(path)
        if section is None:
            continue
        if start:
            start -= 1
            continue
        if len(apps) == 10:
            break
        icon_name = section.get('Icon', 'application-x-executable')
        try:
            if os.path.isabs(icon_name):
                from gi.repository import GdkPixbuf
                icon = GdkPixbuf.Pixbuf.new_from_file_at_scale(icon_name, 128, 128, True)
            else:
                icon = theme.load_icon(icon_name, 128, Gtk.IconLookupFlags.FORCE_SIZE)
            _, png = icon.save_to_bufferv('png', [], [])
            icon_url = 'data:image/png;base64,' + base64.b64encode(png).decode('ascii')
        except Exception:
            icon = theme.load_icon('application-x-executable', 128, Gtk.IconLookupFlags.FORCE_SIZE)
            _, png = icon.save_to_bufferv('png', [], [])
            icon_url = 'data:image/png;base64,' + base64.b64encode(png).decode('ascii')
        apps.append({'id': ident, 'name': section['Name'], 'icon': icon_url,
                     'categories': [s for s in section.get('Categories', '').split(';') if s], 'exec': section['Exec']})
    print(json.dumps(apps))
