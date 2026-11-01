"""List and launch desktop entries using the guest's own desktop environment."""
import configparser
import json
import os
import pathlib
import re
import shlex
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
            # An entry whose TryExec program is gone is absent (Desktop Entry Specification), so
            # a stale copy, such as one carried over in a home folder, never shadows an installed app.
            if missing_program(path):
                continue
            # Record hidden overrides, too, so a lower-priority entry stays hidden.
            found[ident] = path
    return found

def missing_program(path):
    parser = configparser.ConfigParser(interpolation=None, strict=False)
    parser.optionxform = str
    try:
        parser.read(path, encoding='utf-8')
        program = parser['Desktop Entry'].get('TryExec')
    except (OSError, ValueError, KeyError, configparser.Error):
        return False
    return bool(program) and not shutil.which(program)

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

# Electron applications build their pages' accessibility trees only with this switch. The
# trees give the phone its touch targets and name the window controls an application draws
# in its own page, which Caboose hides: every window already has Caboose's own.
ELECTRON_SWITCH = '--force-renderer-accessibility'
# On the seat that renders on the phone's GPU (its display names the broker's socket), an
# Electron application renders as Chromium does there (guest/container/chromium-gpu): with
# ANGLE on Vulkan, which reaches the phone's driver, as an X11 client, and outside the GPU
# sandbox that would keep it from the socket. Electron reads no Chromium flags file.
ELECTRON_GPU_SWITCHES = ('--ozone-platform=x11', '--ignore-gpu-blocklist', '--use-gl=angle',
                         '--use-angle=vulkan', '--enable-features=Vulkan,VulkanFromANGLE,DefaultANGLEVulkan',
                         '--disable-gpu-sandbox', '--disable-gpu-process-crash-limit')
# With the Caboose VA-API driver, video decodes on the phone, as in Chromium there
# (docs/gpu-media.md): the same switches, VA-API decoding on the computer's render node.
ELECTRON_VA_FEATURES = ',VaapiVideoDecoder,VaapiIgnoreDriverChecks,VaapiVideoDecodeLinuxGL,' \
    'AcceleratedVideoDecodeLinuxGL,AcceleratedVideoDecodeLinuxZeroCopyGL'

def render_node():
    """The computer's vgem render node (docs/gpu-buffers.md), or None."""
    for node in sorted(pathlib.Path('/dev/dri').glob('renderD*')):
        if pathlib.Path(os.path.realpath(f'/sys/class/drm/{node.name}/device')).name == 'vgem':
            return str(node)
    return None

def electron(exec_line):
    """Whether an Exec line starts an Electron (or other Chromium-packaged) binary itself:
    its directory holds Chromium's resource packs and V8 snapshot beside `resources/`."""
    try:
        argv = shlex.split(exec_line)
    except ValueError:
        return False
    program = shutil.which(argv[0]) if argv else None
    if not program:
        return False
    here = pathlib.Path(os.path.realpath(program)).parent
    return ((here / 'resources').is_dir() and (here / 'v8_context_snapshot.bin').is_file()
            and any((here / pack).is_file() for pack in ('resources.pak', 'chrome_100_percent.pak')))

def electron_switches(exec_line):
    """The switches an Electron Exec line lacks on this seat."""
    switches = [ELECTRON_SWITCH]
    if os.environ.get('CABOOSE_GFXSTREAM_SOCKET') and os.environ.get('DISPLAY'):
        switches += ELECTRON_GPU_SWITCHES
        node = render_node() if os.environ.get('LIBVA_DRIVER_NAME') == 'caboose' else None
        if node:
            switches = [switch + ELECTRON_VA_FEATURES if switch.startswith('--enable-features=') else switch
                        for switch in switches] + [f'--hardware-video-device-path={node}']
    try:
        present = set(shlex.split(exec_line))
    except ValueError:
        present = set()
    return [switch for switch in switches if switch not in present]

def for_electron(entry, section):
    """The entry to launch: for an Electron binary, a copy under the runtime directory whose
    Exec adds electron_switches(), with the same file name (the launch still names the entry)."""
    exec_line = section['Exec']
    switches = electron_switches(exec_line) if electron(exec_line) else []
    if not switches:
        return entry
    runtime = pathlib.Path(os.environ.get('XDG_RUNTIME_DIR') or f'/tmp/caboose-{os.getuid()}') / 'caboose-launch'
    runtime.mkdir(mode=0o700, parents=True, exist_ok=True)
    copy = runtime / entry.name
    lines = []
    for line in entry.read_text(encoding='utf-8').splitlines():
        if re.match(r'^Exec\s*=', line):
            line = ' '.join([line, *switches])
        lines.append(line)
    copy.write_text('\n'.join(lines) + '\n', encoding='utf-8')
    return copy

def enter_scope(ident):
    """Asks caboose-scopes (guest/scopes) to put this process in a new app scope, so the
    launch and everything it starts are one app. Without the daemon (a microVM, an older
    computer) the app still starts, unscoped."""
    import socket
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
            sock.settimeout(5)
            sock.connect('/run/caboose/scopes.sock')
            sock.sendall(json.dumps({'op': 'scope', 'desktopId': ident}).encode() + b'\n')
            sock.makefile('rb').readline(4096)
    except OSError:
        pass

if sys.argv[1] == 'desktop-shortcut':
    desktop_shortcut(sys.argv[2])
    sys.exit(0)

# `launch <id> [home-relative file]` starts an entry; `action <id> <action>` starts one of its actions.
if sys.argv[1] in ('launch', 'action'):
    if sys.argv[1] == 'action' and len(sys.argv) != 4:
        raise SystemExit('Usage: action <id> <action>')
    # Mesa D3D12 on WSL, except on the seat that renders on the phone's GPU, where OpenGL
    # goes through Zink (docs/gpu-live.md, "Applications").
    if os.environ.get('CABOOSE_GPU') == 'wsl' and not os.environ.get('CABOOSE_GFXSTREAM_SOCKET'):
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
    enter_scope(sys.argv[2])
    # GLib handles desktop field codes and does not interpret the Exec as shell; this is
    # what `gio launch` does, without needing the CLI (libglib2.0-bin) in the image.
    import gi
    gi.require_version('Gio', '2.0')
    from gi.repository import Gio
    info = Gio.DesktopAppInfo.new_from_filename(str(for_electron(entry, section)))
    if info is None:
        raise SystemExit('Application could not be started')
    # Everything the launch starts inherits the entry's id, through wrapper scripts and game
    # launchers, so caboose-display can name the entry a window came from (its desktop_id).
    context = Gio.AppLaunchContext()
    context.setenv('CABOOSE_DESKTOP_ID', sys.argv[2])
    # The app inherits this process's stdio. Left as the exec pipes, they stay open for the
    # app's lifetime and the host waits out its timeout before the launch returns.
    devnull = os.open(os.devnull, os.O_RDWR)
    saved = os.dup(2)
    for fd in (0, 1, 2):
        os.dup2(devnull, fd)
    try:
        if action is not None:
            # GLib runs the action's Exec, or activates it over D-Bus; it reports no result.
            info.launch_action(action, context)
            launched = True
        else:
            files = []
            if len(sys.argv) > 3:
                relative = sys.argv[3]
                if not relative or relative.startswith('/') or any(part in ('', '.', '..') for part in relative.split('/')) or '\0' in relative:
                    raise ValueError('Invalid file path')
                files = [Gio.File.new_for_path(str(pathlib.Path.home() / relative))]
            launched = info.launch(files, context)
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
                     'actions': actions(section),
                     'startupWMClass': section.get('StartupWMClass', '').strip()[:256] or None})
    print(json.dumps(apps))
