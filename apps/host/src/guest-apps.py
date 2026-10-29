"""List and launch desktop entries using the guest's own desktop environment."""
import configparser
import json
import os
import pathlib
import re
import shutil
import sys

# Flatpak exports the desktop entries and icons of the system installation's apps.
FLATPAK = pathlib.Path('/var/lib/flatpak/exports/share')
ROOTS = [pathlib.Path.home() / '.local/share/applications', pathlib.Path('/usr/local/share/applications'), FLATPAK / 'applications', pathlib.Path('/usr/share/applications')]

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

# Desktop action identifiers are [A-Za-z0-9-] (Desktop Entry Specification, Additional
# applications actions); the bounds keep a listing small whatever an entry declares.
ACTION_ID = re.compile(r'[A-Za-z0-9-]{1,64}')
MAX_ACTIONS = 16
MAX_ACTION_NAME = 100

def actions(section):
    """The entry's launchable actions, in declared order: those with a group and a Name, and
    an Exec unless the application is D-Bus activated (then GLib activates the action)."""
    found, seen = [], set()
    dbus = section.get('DBusActivatable', '').strip() == 'true'
    for ident in section.get('Actions', '').split(';'):
        ident = ident.strip()
        if not ACTION_ID.fullmatch(ident) or ident in seen:
            continue
        seen.add(ident)
        group = f'Desktop Action {ident}'
        if not section.parser.has_section(group):
            continue
        action = section.parser[group]
        name = action.get('Name', '').strip()
        if not name or not (dbus or action.get('Exec', '').strip()):
            continue
        found.append({'id': ident, 'name': name[:MAX_ACTION_NAME]})
        if len(found) == MAX_ACTIONS:
            break
    return found

def desktop_shortcut(ident):
    """Copy an installed entry; publish atomically, never replace an owner's item."""
    if not ident.endswith('.desktop') or '/' in ident or len(ident) > 240 or any(ord(c) < 32 for c in ident):
        raise SystemExit('Invalid application id')
    entry = entries().get(ident)
    section = read(entry) if entry else None
    if section is None:
        raise SystemExit('Application not found')
    with open(entry, 'rb') as source:
        data = source.read(262145)
    if len(data) > 262144:
        raise SystemExit('Desktop entry is too large')
    # This reference is interpreted only as an installed ID by iOS, never as Exec.
    parser = configparser.ConfigParser(interpolation=None, strict=False)
    parser.optionxform = str
    parser.read_string(data.decode('utf-8'))
    parser['Desktop Entry']['X-Caboose-AppId'] = ident
    import io, uuid
    output = io.StringIO()
    parser.write(output, space_around_delimiters=False)
    desktop = pathlib.Path.home() / 'Desktop'
    desktop.mkdir(exist_ok=True)
    # A directory fd prevents a renamed/replaced Desktop from redirecting publication.
    fd = os.open(desktop, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    temporary = '.caboose-shortcut-' + uuid.uuid4().hex
    try:
        out = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o755, dir_fd=fd)
        with os.fdopen(out, 'w', encoding='utf-8') as target:
            target.write(output.getvalue())
            target.flush()
            os.fsync(target.fileno())
        try:
            os.link(temporary, ident, src_dir_fd=fd, dst_dir_fd=fd, follow_symlinks=False)
        except FileExistsError:
            raise SystemExit('Desktop shortcut already exists')
    finally:
        try: os.unlink(temporary, dir_fd=fd)
        finally: os.close(fd)
    print(json.dumps({'path': 'Desktop/' + ident}))

if sys.argv[1] == 'desktop-shortcut':
    desktop_shortcut(sys.argv[2])
    sys.exit(0)

# `launch <id> [home-relative file]` starts an entry; `action <id> <action>` starts one of its actions.
if sys.argv[1] in ('launch', 'action'):
    if sys.argv[1] == 'action' and len(sys.argv) != 4:
        raise SystemExit('Usage: action <id> <action>')
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
    section = read(entry) if entry else None
    if section is None:
        raise SystemExit('Application not found')
    action = sys.argv[3] if sys.argv[1] == 'action' else None
    if action is not None and action not in {item['id'] for item in actions(section)}:
        raise SystemExit('Application action not found')
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
        if action is not None:
            # GLib runs the action's Exec, or activates it over D-Bus; it reports no result.
            info.launch_action(action, None)
            launched = True
        else:
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
    if (FLATPAK / 'icons').is_dir():
        theme.append_search_path(str(FLATPAK / 'icons'))
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
                     'categories': [s for s in section.get('Categories', '').split(';') if s], 'exec': section['Exec'],
                     'actions': actions(section)})
    print(json.dumps(apps))
