#!/usr/bin/env python3
"""Direct tools: what an application or the system can do without its GUI, as typed tools.

usage: direct.py serve

Run by desktop MCP with the agent seat's launch environment (its session bus, its profile's
home and settings), one JSON request per line on stdin and one JSON reply per line:

  {"op": "list", "window": W}               -> {"tools": [{"name", "params", "description"}]}
  {"op": "call", "window": W, "name", "args"} -> {"result": text} | {"error": text}

W describes the focused window: {"pid", "app_id", "desktop_id", "title"}. The tools come
from general mechanisms, found for whichever application has the window:

- app.* and win.*: the application's GApplication actions (org.gtk.Actions on its D-Bus
  name), win.* those of its one exported window;
- desktop.*: the actions of its desktop entry ([Desktop Action]);
- media.*: its MPRIS player (org.mpris.MediaPlayer2.*);
- folder.show: its org.freedesktop.FileManager1 service;
- settings.get, settings.set: its GSettings schemas (a schema whose id has the application's
  name as a component) and its xfconf channel (the channel named like the application),
  typed by the schema or the stored value;
- doc.*: its document through LibreOffice's UNO, for a LibreOffice started by the launcher
  (which opens the seat's UNO pipe);
- browser.*: its tabs through the Caboose WebMCP extension (the DevTools protocol), for
  Chromium on the agent seat;
- kde.*: the actions of a KDE application's main window (org.kde.KMainWindow);
- chooser.answer, chooser.cancel: an open portal file dialog, answered with a path in the
  agent's home without the dialog (caboose-portal's com.caboose.FileChooserAnswers);
- files.*: files in the agent's home, for every window; trash, never delete.

Everything acts in the agent seat's session only: its bus, its profile's home."""
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import tarfile
import zipfile

UNO_PIPE = 'caboose-agent-uno'
MAX_READ = 20000
LAUNCHER = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'launcher.py')


class Failure(Exception):
    pass


def _gi():
    import gi
    gi.require_version('Gio', '2.0')
    from gi.repository import Gio, GLib
    return Gio, GLib


_bus = None


def bus():
    global _bus
    if _bus is None:
        Gio, _ = _gi()
        _bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
    return _bus


def dbus_call(name, path, interface, method, args=None, reply=None, timeout=5000):
    Gio, GLib = _gi()
    result = bus().call_sync(name, path, interface, method, args, GLib.VariantType(reply) if reply else None,
                             Gio.DBusCallFlags.NONE, timeout, None)
    return result.unpack() if result is not None else None


def names_of(pid, app_id=None):
    """Well-known names on the session bus of the application: those its process `pid` owns,
    and those named after its id (a sandboxed application's names belong to its bus proxy:
    the id itself, or the id with a suffix, as KDE's org.kde.kate-1234)."""
    if not pid:
        return []
    found = []
    for name in dbus_call('org.freedesktop.DBus', '/org/freedesktop/DBus', 'org.freedesktop.DBus', 'ListNames', None, '(as)')[0]:
        if name.startswith(':'):
            continue
        if app_id and (name == app_id or name.startswith(app_id + '.') or name.startswith(app_id + '-')):
            found.append(name)
            continue
        try:
            owner = dbus_call('org.freedesktop.DBus', '/org/freedesktop/DBus', 'org.freedesktop.DBus',
                              'GetConnectionUnixProcessID', _v('(s)', (name,)), '(u)')[0]
        except Exception:
            continue
        if owner == pid:
            found.append(name)
    return found


def _v(signature, value):
    _, GLib = _gi()
    return GLib.Variant(signature, value)


def type_name(signature):
    return {'b': 'boolean', 's': 'string', 'i': 'integer', 'u': 'integer', 'x': 'integer', 't': 'integer', 'n': 'integer',
            'q': 'integer', 'y': 'integer', 'd': 'number', 'as': 'string list', 'o': 'string'}.get(signature, signature)


def to_variant(signature, value):
    """A JSON value as a GVariant of `signature`."""
    _, GLib = _gi()
    try:
        if signature in ('i', 'u', 'x', 't', 'n', 'q', 'y'):
            return GLib.Variant(signature, int(value))
        if signature == 'd':
            return GLib.Variant('d', float(value))
        if signature == 'b':
            if isinstance(value, str):
                value = {'true': True, 'false': False}.get(value.lower(), value)
            if not isinstance(value, bool):
                raise ValueError
            return GLib.Variant('b', value)
        if signature in ('s', 'o'):
            return GLib.Variant(signature, str(value))
        if isinstance(value, str):
            return GLib.Variant.parse(GLib.VariantType(signature), value, None, None)
        return GLib.Variant(signature, value)
    except (ValueError, TypeError, GLib.Error):
        raise Failure(f'expected a value of type {type_name(signature)}')


# --- Files in the agent's home ------------------------------------------------------------

def home():
    return os.path.realpath(os.environ.get('HOME') or '/nonexistent')


def inside(path, must_exist=False):
    """`path` (absolute, ~/…, or relative to the home) resolved inside the agent's home."""
    if not isinstance(path, str) or not path:
        raise Failure('a path is needed')
    path = os.path.expanduser(path)
    if not os.path.isabs(path):
        path = os.path.join(home(), path)
    real = os.path.realpath(path)
    if real != home() and not real.startswith(home() + os.sep):
        raise Failure(f'{path} is outside the agent\'s home ({home()})')
    if must_exist and not os.path.lexists(real):
        raise Failure(f'{path} does not exist')
    return real


def files_list(args):
    path = inside(args.get('path') or '~', True)
    if not os.path.isdir(path):
        raise Failure(f'{path} is not a folder')
    rows = []
    for name in sorted(os.listdir(path))[:500]:
        full = os.path.join(path, name)
        rows.append(f'{name}/' if os.path.isdir(full) else f'{name} ({os.path.getsize(full)} bytes)')
    return f'{path}:\n' + ('\n'.join(rows) if rows else '(empty)')


def files_read(args):
    path = inside(args.get('path'), True)
    with open(path, 'rb') as f:
        data = f.read(MAX_READ + 1)
    text = data[:MAX_READ].decode('utf-8', 'replace')
    return text + ('\n… (truncated)' if len(data) > MAX_READ else '')


def files_write(args):
    path = inside(args.get('path'))
    text = args.get('text')
    if not isinstance(text, str):
        raise Failure('text is needed')
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'a' if args.get('append') else 'w', encoding='utf-8') as f:
        f.write(text)
    return f'Wrote {len(text)} characters to {path}.'


def files_copy(args, move=False):
    source, target = inside(args.get('from'), True), inside(args.get('to'))
    if os.path.isdir(target):
        target = os.path.join(target, os.path.basename(source))
    os.makedirs(os.path.dirname(target), exist_ok=True)
    if move:
        shutil.move(source, target)
    elif os.path.isdir(source):
        shutil.copytree(source, target)
    else:
        shutil.copy2(source, target)
    return f'{"Moved" if move else "Copied"} {source} to {target}.'


def files_mkdir(args):
    path = inside(args.get('path'))
    os.makedirs(path, exist_ok=True)
    return f'Made {path}.'


def files_trash(args):
    path = inside(args.get('path'), True)
    if path == home():
        raise Failure('the home itself cannot be trashed')
    Gio, _ = _gi()
    Gio.File.new_for_path(path).trash(None)
    return f'Moved {path} to the trash.'


def files_extract(args):
    archive, target = inside(args.get('archive'), True), inside(args.get('to'))
    os.makedirs(target, exist_ok=True)
    names = []
    if zipfile.is_zipfile(archive):
        with zipfile.ZipFile(archive) as z:
            for member in z.infolist():
                inside(os.path.join(target, member.filename))
                names.append(member.filename)
            z.extractall(target)
    elif tarfile.is_tarfile(archive):
        with tarfile.open(archive) as t:
            t.extractall(target, filter='data')
            names = t.getnames()
    else:
        raise Failure(f'{archive} is not a zip or tar archive')
    return f'Extracted {len(names)} entries to {target}: ' + ', '.join(names[:20])


FILES = {
    'files.list': ({'path?': 'string'}, 'List a folder (default: the home).', files_list),
    'files.read': ({'path': 'string'}, 'Read a text file.', files_read),
    'files.write': ({'path': 'string', 'text': 'string', 'append?': 'boolean'}, 'Write (or append to) a text file.', files_write),
    'files.copy': ({'from': 'string', 'to': 'string'}, 'Copy a file or folder.', files_copy),
    'files.move': ({'from': 'string', 'to': 'string'}, 'Move or rename a file or folder.', lambda a: files_copy(a, True)),
    'files.mkdir': ({'path': 'string'}, 'Make a folder (and its parents).', files_mkdir),
    'files.trash': ({'path': 'string'}, 'Move a file or folder to the trash.', files_trash),
    'files.extract': ({'archive': 'string', 'to': 'string'}, 'Extract a zip or tar archive into a folder.', files_extract),
}


# --- GApplication actions ------------------------------------------------------------------

def action_paths(name):
    path = '/' + name.replace('.', '/').replace('-', '_')
    paths = [('app', path)]
    try:
        xml = dbus_call(name, path + '/window', 'org.freedesktop.DBus.Introspectable', 'Introspect', None, '(s)')[0]
        windows = re.findall(r'<node name="(\d+)"', xml)
        if len(windows) == 1:
            paths.append(('win', f'{path}/window/{windows[0]}'))
    except Exception:
        pass
    return paths


def gtk_actions(names):
    tools = {}
    for name in names:
        for prefix, path in action_paths(name):
            try:
                described = dbus_call(name, path, 'org.gtk.Actions', 'DescribeAll', None, '(a{s(bgav)})')[0]
            except Exception:
                continue
            for action, (enabled, param, state) in sorted(described.items()):
                if not enabled:
                    continue
                params = {}
                if param:
                    params['value'] = type_name(param)
                stateful = bool(state)
                if stateful and not param:
                    params['state?'] = type_name(_state_type(name, path, action) or 'b')
                tools[f'{prefix}.{action}'] = (params, 'GApplication action' + (' with a state' if stateful else ''),
                                               ('gtk', name, path, action, param, stateful))
    return tools


def _state(name, path, action):
    try:
        reply = bus().call_sync(name, path, 'org.gtk.Actions', 'Describe', _v('(s)', (action,)), None, 0, 3000, None)
        state = reply.get_child_value(0).get_child_value(2)
        return state.get_child_value(0).get_child_value(0).unpack() if state.n_children() else None
    except Exception:
        return None


def _state_type(name, path, action):
    try:
        _, GLib = _gi()
        reply = bus().call_sync(name, path, 'org.gtk.Actions', 'Describe', _v('(s)', (action,)), None, 0, 3000, None)
        state = reply.get_child_value(0).get_child_value(2)
        return state.get_child_value(0).get_child_value(0).get_type_string() if state.n_children() else None
    except Exception:
        return None


def gtk_call(spec, args):
    _, name, path, action, param, stateful = spec
    _, GLib = _gi()
    empty = GLib.Variant('a{sv}', {})
    if stateful and not param and 'state' in args:
        kind = _state_type(name, path, action) or 'b'
        wanted = to_variant(kind, args['state'])
        if _state(name, path, action) == wanted.unpack():
            return f'{action} is already {json.dumps(wanted.unpack())}.'
        # A toggle goes through the application's own handler, as its menu item does: SetState
        # alone changes the action's state without what the application does on a change (a
        # setting it writes). Activating toggles a boolean; SetState covers the rest.
        if kind == 'b':
            bus().call_sync(name, path, 'org.gtk.Actions', 'Activate',
                            GLib.Variant.new_tuple(GLib.Variant('s', action), GLib.Variant('av', []), empty), None, 0, 5000, None)
        if _state(name, path, action) != wanted.unpack():
            bus().call_sync(name, path, 'org.gtk.Actions', 'SetState',
                            GLib.Variant.new_tuple(GLib.Variant('s', action), GLib.Variant('v', wanted), empty), None, 0, 5000, None)
        return f'Set {action} to {json.dumps(wanted.unpack())}.'
    values = [GLib.Variant('v', to_variant(param, args.get('value')))] if param else []
    bus().call_sync(name, path, 'org.gtk.Actions', 'Activate',
                    GLib.Variant.new_tuple(GLib.Variant('s', action), GLib.Variant('av', values), empty), None, 0, 5000, None)
    return f'Activated {action}.'


# --- Portal file chooser requests ------------------------------------------------------------

PORTAL = 'org.freedesktop.impl.portal.desktop.caboose'


def chooser_requests():
    try:
        return dbus_call(PORTAL, '/com/caboose/FileChooser', 'com.caboose.FileChooserAnswers', 'Pending', None, '(a(sssbb))')[0]
    except Exception:
        return []


def chooser_tools(window):
    requests = chooser_requests()
    if not requests:
        return {}
    handle, method, title, directory, multiple = chooser_request(window, requests)
    what = 'a folder' if directory else 'files' if multiple else 'a file'
    verb = 'save to' if method == 'SaveFile' else f'open ({what})'
    return {'chooser.answer': ({'path': 'string', 'paths?': 'string list'}, f'Answer the file dialog "{title}" with the path to {verb}, without the dialog', ('chooser',)),
            'chooser.cancel': ({}, f'Cancel the file dialog "{title}"', ('chooser',))}


def chooser_request(window, requests):
    titled = [r for r in requests if r[2] and r[2] == window.get('title')]
    return (titled or requests)[-1]


def chooser_call(window, name, args):
    requests = chooser_requests()
    if not requests:
        raise Failure('no file dialog is open')
    handle = chooser_request(window, requests)[0]
    if name == 'chooser.cancel':
        dbus_call(PORTAL, '/com/caboose/FileChooser', 'com.caboose.FileChooserAnswers', 'Cancel', _v('(o)', (handle,)))
        return 'Cancelled the dialog.'
    paths = args.get('paths') or ([args['path']] if args.get('path') else [])
    if not isinstance(paths, list) or not paths:
        raise Failure('give path (or paths)')
    resolved = [inside(p) for p in paths]
    _, GLib = _gi()
    try:
        dbus_call(PORTAL, '/com/caboose/FileChooser', 'com.caboose.FileChooserAnswers', 'Answer', _v('(oas)', (handle, resolved)))
    except GLib.Error as error:
        raise Failure(error.message.split(': ', 1)[-1] if hasattr(error, 'message') else str(error))
    return f'Answered the dialog with {", ".join(resolved)}.'


# --- KDE main window actions ---------------------------------------------------------------

def kde_actions(names):
    """The actions of a KDE application's one main window (org.kde.KMainWindow: its menus and
    toolbars' actions, by name)."""
    tools = {}
    for name in names:
        try:
            top = dbus_call(name, '/', 'org.freedesktop.DBus.Introspectable', 'Introspect', None, '(s)')[0]
        except Exception:
            continue
        windows = []
        for node in re.findall(r'<node name="([^"]+)"', top):
            try:
                xml = dbus_call(name, f'/{node}', 'org.freedesktop.DBus.Introspectable', 'Introspect', None, '(s)')[0]
            except Exception:
                continue
            windows += [f'/{node}/{child}' for child in re.findall(r'<node name="(MainWindow_\d+)"', xml)]
        if len(windows) != 1:
            continue
        try:
            actions = dbus_call(name, windows[0], 'org.kde.KMainWindow', 'actions', None, '(as)')[0]
        except Exception:
            continue
        for action in actions:
            if action and re.fullmatch(r'[\w.-]+', action):
                tools[f'kde.{action}'] = ({}, 'KDE main window action', ('kde', name, windows[0], action))
    return tools


def kde_call(spec, _args):
    _, name, path, action = spec
    if not dbus_call(name, path, 'org.kde.KMainWindow', 'actionIsEnabled', _v('(s)', (action,)), '(b)')[0]:
        raise Failure(f'{action} is disabled now')
    dbus_call(name, path, 'org.kde.KMainWindow', 'activateAction', _v('(s)', (action,)), '(b)')
    return f'Activated {action}.'


# --- Desktop entry actions -----------------------------------------------------------------

def desktop_file(window):
    candidates = [window.get('desktop_id'), (window.get('app_id') or '') + '.desktop']
    dirs = [os.path.join(os.environ.get('XDG_DATA_HOME') or os.path.expanduser('~/.local/share'), 'applications')]
    dirs += [os.path.join(d, 'applications') for d in (os.environ.get('XDG_DATA_DIRS') or '/usr/local/share:/usr/share').split(':')]
    dirs += ['/var/lib/flatpak/exports/share/applications']
    for candidate in filter(None, candidates):
        for directory in dirs:
            path = os.path.join(directory, candidate)
            if os.path.isfile(path):
                return path
    return None


def desktop_actions(window):
    path = desktop_file(window)
    if not path:
        return {}
    import configparser
    entry = configparser.ConfigParser(interpolation=None, strict=False)
    try:
        entry.read(path, encoding='utf-8')
    except (configparser.Error, OSError):
        return {}
    tools = {}
    for action in (entry.get('Desktop Entry', 'Actions', fallback='') or '').split(';'):
        section = f'Desktop Action {action}'
        if action and entry.has_section(section) and entry.has_option(section, 'Exec'):
            command = re.sub(r'%[fFuUdDnNickvm]', '', entry.get(section, 'Exec')).strip()
            tools[f'desktop.{action}'] = ({}, entry.get(section, 'Name', fallback=action), ('desktop', command))
    return tools


def desktop_call(spec, _args):
    subprocess.Popen([sys.executable, LAUNCHER, spec[1]], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                     stderr=subprocess.DEVNULL, start_new_session=True)
    return f'Started {spec[1]}.'


# --- MPRIS and FileManager1 ------------------------------------------------------------------

MEDIA = {'play': 'Play', 'pause': 'Pause', 'play_pause': 'PlayPause', 'next': 'Next', 'previous': 'Previous', 'stop': 'Stop'}


def media_tools(names):
    tools = {}
    for name in names:
        if name.startswith('org.mpris.MediaPlayer2.'):
            for tool, method in MEDIA.items():
                tools[f'media.{tool}'] = ({}, f'MPRIS {method}', ('mpris', name, method))
            tools['media.status'] = ({}, 'What is playing, and the playback state', ('mpris', name, None))
            tools['media.open'] = ({'uri': 'string'}, 'Play a file or URL', ('mpris', name, 'OpenUri'))
            break
    return tools


def media_call(spec, args):
    _, name, method = spec
    path, player = '/org/mpris/MediaPlayer2', 'org.mpris.MediaPlayer2.Player'
    if method is None:
        props = dbus_call(name, path, 'org.freedesktop.DBus.Properties', 'GetAll', _v('(s)', (player,)), '(a{sv})')[0]
        meta = props.get('Metadata') or {}
        return json.dumps({'status': props.get('PlaybackStatus'), 'title': meta.get('xesam:title'), 'artist': meta.get('xesam:artist'),
                           'url': meta.get('xesam:url'), 'position_s': round((props.get('Position') or 0) / 1e6, 1)})
    if method == 'OpenUri':
        uri = args.get('uri')
        if not isinstance(uri, str) or not uri:
            raise Failure('uri is needed')
        if '://' not in uri:
            uri = 'file://' + inside(uri, True)
        dbus_call(name, path, player, 'OpenUri', _v('(s)', (uri,)))
        return f'Opened {uri}.'
    dbus_call(name, path, player, method)
    return f'{method} sent.'


def folder_tools(names):
    if 'org.freedesktop.FileManager1' in names:
        return {'folder.show': ({'path': 'string'}, 'Show a folder in this file manager', ('fm',))}
    return {}


def folder_call(_spec, args):
    path = inside(args.get('path'), True)
    dbus_call('org.freedesktop.FileManager1', '/org/freedesktop/FileManager1', 'org.freedesktop.FileManager1', 'ShowFolders',
              _v('(ass)', (['file://' + path], '')))
    return f'Showing {path}.'


# --- Settings ----------------------------------------------------------------------------------

def app_words(window):
    words = set()
    for value in (window.get('app_id'), (window.get('desktop_id') or '').removesuffix('.desktop')):
        if value:
            words.add(value.lower())
            words.add(value.split('.')[-1].lower())
    return {w for w in words if len(w) >= 3}


def app_schemas(window):
    Gio, _ = _gi()
    source = Gio.SettingsSchemaSource.get_default()
    if source is None:
        return []
    schemas, _ = source.list_schemas(True)
    words = app_words(window)
    found = []
    for schema_id in schemas:
        parts = [p.lower() for p in schema_id.split('.')]
        if schema_id.lower() in words or any(p in words for p in parts[1:]):
            schema = source.lookup(schema_id, True)
            if schema is not None and schema.list_keys():
                found.append(schema)
    return found


def xfconf_channels(window):
    try:
        channels = dbus_call('org.xfce.Xfconf', '/org/xfce/Xfconf', 'org.xfce.Xfconf', 'ListChannels', None, '(as)')[0]
    except Exception:
        return []
    words = app_words(window)
    return [c for c in channels if c.lower() in words]


def settings_tools(window):
    if not app_schemas(window) and not xfconf_channels(window):
        return {}
    return {'settings.get': ({'filter?': 'string'}, "The application's settings: each key's type and value", ('settings',)),
            'settings.set': ({'key': 'string', 'value': 'any'}, 'Set one setting, by its key from settings.get', ('settings',))}


def describe_range(key):
    kind, values = key.get_range().unpack()
    if kind == 'enum':
        return ' one of ' + '|'.join(values)
    if kind == 'range':
        return f' {values[0]}–{values[1]}'
    return ''


def settings_get(window, args):
    Gio, _ = _gi()
    query = (args.get('filter') or '').lower()
    rows = []
    for schema in app_schemas(window):
        settings = Gio.Settings.new_full(schema, None, None)
        for name in sorted(schema.list_keys()):
            key_id = f'{schema.get_id()}/{name}'
            if query and query not in key_id.lower():
                continue
            key = schema.get_key(name)
            value = settings.get_value(name).unpack()
            rows.append(f'{key_id} ({type_name(key.get_value_type().dup_string())}{describe_range(key)}) = {json.dumps(value)}')
    for channel in xfconf_channels(window):
        props = dbus_call('org.xfce.Xfconf', '/org/xfce/Xfconf', 'org.xfce.Xfconf', 'GetAllProperties', _v('(ss)', (channel, '/')), '(a{sv})')[0]
        for prop, value in sorted(props.items()):
            key_id = f'xfconf:{channel}{prop}'
            if query and query not in key_id.lower():
                continue
            rows.append(f'{key_id} ({type(value).__name__.replace("str", "string").replace("bool", "boolean").replace("int", "integer")}) = {json.dumps(value)}')
    return '\n'.join(rows[:300]) or 'No setting matches.'


def settings_set(window, args):
    Gio, GLib = _gi()
    key_id, value = args.get('key'), args.get('value')
    if not isinstance(key_id, str) or ('/' not in key_id):
        raise Failure('key must be one settings.get lists, such as org.xfce.mousepad.preferences.view/word-wrap')
    if key_id.startswith('xfconf:'):
        channel, _, prop = key_id[len('xfconf:'):].partition('/')
        if channel not in xfconf_channels(window):
            raise Failure(f'no xfconf channel {channel} for this application')
        prop = '/' + prop
        props = dbus_call('org.xfce.Xfconf', '/org/xfce/Xfconf', 'org.xfce.Xfconf', 'GetAllProperties', _v('(ss)', (channel, '/')), '(a{sv})')[0]
        current = props.get(prop)
        signature = {bool: 'b', int: 'i', float: 'd', str: 's'}.get(type(current), 'b' if isinstance(value, bool) else 'i' if isinstance(value, int) else 's')
        bus().call_sync('org.xfce.Xfconf', '/org/xfce/Xfconf', 'org.xfce.Xfconf', 'SetProperty',
                        GLib.Variant.new_tuple(GLib.Variant('s', channel), GLib.Variant('s', prop), GLib.Variant('v', to_variant(signature, value))),
                        None, 0, 5000, None)
        return f'Set {key_id} to {json.dumps(value)}.'
    schema_id, _, name = key_id.rpartition('/')
    schema = next((s for s in app_schemas(window) if s.get_id() == schema_id), None)
    if schema is None or not schema.has_key(name):
        raise Failure(f'no setting {key_id} for this application; settings.get lists them')
    key = schema.get_key(name)
    variant = to_variant(key.get_value_type().dup_string(), value)
    if not key.range_check(variant):
        raise Failure(f'{json.dumps(value)} is out of range for {key_id}:{describe_range(key)}')
    settings = Gio.Settings.new_full(schema, None, None)
    settings.set_value(name, variant)
    Gio.Settings.sync()
    return f'Set {key_id} to {json.dumps(variant.unpack())}.'


# --- LibreOffice through UNO -----------------------------------------------------------------

def is_office(pid):
    try:
        return os.path.basename(os.readlink(f'/proc/{pid}/exe')) == 'soffice.bin'
    except OSError:
        return False


def office_tools(window):
    if not is_office(window.get('pid')):
        return {}
    try:
        document(window)
    except Failure:
        return {}
    return {
        'doc.info': ({}, 'The document: kind, title, file, sheets or slides', ('doc',)),
        'doc.text': ({}, "The document's text (a sheet's used cells as rows, each slide's texts)", ('doc',)),
        'doc.cells': ({'range': 'string', 'sheet?': 'string'}, 'Read cells (A1:C5) of a spreadsheet', ('doc',)),
        'doc.set_cells': ({'at': 'string', 'values': 'rows of values', 'sheet?': 'string'},
                          'Write rows of values from a cell; text starting with = is a formula', ('doc',)),
        'doc.append': ({'text': 'string', 'bold?': 'boolean'}, 'Add a paragraph at the end of a text document', ('doc',)),
        'doc.replace': ({'search': 'string', 'replace': 'string', 'any_case?': 'boolean'}, 'Replace every occurrence (matching case unless any_case); says how many', ('doc',)),
        'doc.slide': ({'index': 'integer', 'title?': 'string', 'body?': 'string'}, "Set a slide's title and body text (1 = first)", ('doc',)),
        'doc.save': ({'path?': 'string'}, 'Save; with a path, save as that file (its extension picks the format: odt, docx, pdf, ods, xlsx, csv, odp, pptx)', ('doc',)),
    }


def office():
    try:
        import uno
    except ImportError:
        raise Failure('LibreOffice UNO for Python (python3-uno) is not installed')
    local = uno.getComponentContext()
    resolver = local.ServiceManager.createInstanceWithContext('com.sun.star.bridge.UnoUrlResolver', local)
    try:
        context = resolver.resolve(f'uno:pipe,name={UNO_PIPE};urp;StarOffice.ComponentContext')
    except Exception:
        raise Failure('this LibreOffice was not started by the launcher with its UNO pipe')
    return uno, context.ServiceManager.createInstanceWithContext('com.sun.star.frame.Desktop', context)


def document(window):
    uno, desktop = office()
    title = window.get('title') or ''
    components = desktop.getComponents().createEnumeration()
    best = None
    while components.hasMoreElements():
        component = components.nextElement()
        try:
            frame = component.getCurrentController().getFrame().getTitle()
        except Exception:
            continue
        if frame and (title == frame or title.startswith(frame)):
            best = component
    best = best or desktop.getCurrentComponent()
    if best is None:
        raise Failure('no LibreOffice document has this window')
    return best


def kind(doc):
    for service, name in (('com.sun.star.sheet.SpreadsheetDocument', 'spreadsheet'), ('com.sun.star.presentation.PresentationDocument', 'presentation'),
                          ('com.sun.star.text.TextDocument', 'text'), ('com.sun.star.drawing.DrawingDocument', 'drawing')):
        if doc.supportsService(service):
            return name
    return 'document'


def sheet_of(doc, name):
    sheets = doc.getSheets()
    if name:
        if not sheets.hasByName(name):
            raise Failure(f'no sheet {name}; sheets: {", ".join(sheets.getElementNames())}')
        return sheets.getByName(name)
    return doc.getCurrentController().getActiveSheet()


def cell_value(cell):
    formula = cell.getFormula()
    if formula.startswith('='):
        return {'formula': formula, 'shows': cell.getString()}
    return cell.getValue() if cell.getType().value == 'VALUE' else cell.getString()


FILTERS = {('text', 'docx'): 'MS Word 2007 XML', ('text', 'doc'): 'MS Word 97', ('text', 'pdf'): 'writer_pdf_Export', ('text', 'odt'): 'writer8',
           ('text', 'txt'): 'Text', ('text', 'html'): 'HTML (StarWriter)', ('spreadsheet', 'xlsx'): 'Calc MS Excel 2007 XML',
           ('spreadsheet', 'ods'): 'calc8', ('spreadsheet', 'csv'): 'Text - txt - csv (StarCalc)', ('spreadsheet', 'pdf'): 'calc_pdf_Export',
           ('presentation', 'pptx'): 'Impress MS PowerPoint 2007 XML', ('presentation', 'odp'): 'impress8', ('presentation', 'pdf'): 'impress_pdf_Export'}


def office_call(window, name, args):
    uno, _ = office()
    from com.sun.star.beans import PropertyValue
    doc = document(window)
    what = kind(doc)

    def prop(key, value):
        p = PropertyValue(); p.Name = key; p.Value = value
        return p

    if name == 'doc.info':
        info = {'kind': what, 'title': doc.getCurrentController().getFrame().getTitle(), 'file': doc.getURL() or None, 'modified': doc.isModified()}
        if what == 'spreadsheet':
            info['sheets'] = list(doc.getSheets().getElementNames())
        if what == 'presentation':
            info['slides'] = doc.getDrawPages().getCount()
        return json.dumps(info)
    if name == 'doc.text':
        if what == 'text':
            text = doc.getText().getString()
        elif what == 'spreadsheet':
            sheet = sheet_of(doc, args.get('sheet'))
            cursor = sheet.createCursor(); cursor.gotoEndOfUsedArea(False)
            end = cursor.getRangeAddress()
            rows = sheet.getCellRangeByPosition(0, 0, end.EndColumn, end.EndRow).getDataArray()
            text = '\n'.join('\t'.join(str(v) for v in row) for row in rows)
        else:
            parts = []
            pages = doc.getDrawPages()
            for i in range(pages.getCount()):
                page = pages.getByIndex(i)
                texts = [page.getByIndex(j).getString() for j in range(page.getCount()) if hasattr(page.getByIndex(j), 'getString')]
                parts.append(f'Slide {i + 1}: ' + ' | '.join(t for t in texts if t))
            text = '\n'.join(parts)
        return text[:MAX_READ]
    if name == 'doc.cells':
        if what != 'spreadsheet':
            raise Failure('doc.cells is for spreadsheets')
        block = sheet_of(doc, args.get('sheet')).getCellRangeByName(str(args.get('range') or 'A1'))
        rows = block.getRangeAddress()
        out = []
        for r in range(rows.EndRow - rows.StartRow + 1):
            out.append([cell_value(block.getCellByPosition(c, r)) for c in range(rows.EndColumn - rows.StartColumn + 1)])
        return json.dumps(out)
    if name == 'doc.set_cells':
        if what != 'spreadsheet':
            raise Failure('doc.set_cells is for spreadsheets')
        values = args.get('values')
        if not isinstance(values, list) or not values:
            raise Failure('values must be rows, such as [[1, 2], ["=SUM(A1:B1)"]]')
        values = [row if isinstance(row, list) else [row] for row in values]
        start = sheet_of(doc, args.get('sheet')).getCellRangeByName(str(args.get('at') or 'A1')).getCellByPosition(0, 0)
        sheet = sheet_of(doc, args.get('sheet'))
        address = start.getCellAddress()
        for r, row in enumerate(values):
            for c, value in enumerate(row):
                cell = sheet.getCellByPosition(address.Column + c, address.Row + r)
                if isinstance(value, bool) or value is None:
                    cell.setString('' if value is None else str(value).upper())
                elif isinstance(value, (int, float)):
                    cell.setValue(value)
                else:
                    cell.setFormula(str(value)) if str(value).startswith('=') else cell.setString(str(value))
        return f'Wrote {sum(len(r) for r in values)} cells from {args.get("at") or "A1"}.'
    if name == 'doc.append':
        if what != 'text':
            raise Failure('doc.append is for text documents')
        text = doc.getText()
        cursor = text.createTextCursor(); cursor.gotoEnd(False)
        if text.getString():
            text.insertControlCharacter(cursor, 0, False)  # PARAGRAPH_BREAK
        cursor.setPropertyValue('CharWeight', 150.0 if args.get('bold') else 100.0)
        text.insertString(cursor, str(args.get('text') or ''), False)
        return 'Appended a paragraph.'
    if name == 'doc.replace':
        search = args.get('search')
        if not isinstance(search, str) or not search:
            raise Failure('search is needed')
        if what == 'spreadsheet':
            target = sheet_of(doc, args.get('sheet'))
        elif what == 'text':
            target = doc
        else:
            raise Failure('doc.replace is for text documents and spreadsheets')
        descriptor = target.createReplaceDescriptor()
        descriptor.setSearchString(search); descriptor.setReplaceString(str(args.get('replace') or ''))
        descriptor.SearchCaseSensitive = not args.get('any_case')
        return f'Replaced {target.replaceAll(descriptor)} occurrences.'
    if name == 'doc.slide':
        if what != 'presentation':
            raise Failure('doc.slide is for presentations')
        pages = doc.getDrawPages()
        index = int(args.get('index') or 1) - 1
        if not 0 <= index < pages.getCount():
            raise Failure(f'there are {pages.getCount()} slides')
        page = pages.getByIndex(index)
        done = []
        for j in range(page.getCount()):
            shape = page.getByIndex(j)
            kind_ = shape.getShapeType()
            if 'TitleText' in kind_ and 'title' in args:
                shape.setString(str(args['title'])); done.append('title')
            elif ('Outliner' in kind_ or 'Subtitle' in kind_) and 'body' in args:
                shape.setString(str(args['body'])); done.append('body')
        return f'Set {", ".join(done) or "nothing (the slide has no title or body placeholder)"} on slide {index + 1}.'
    if name == 'doc.save':
        path = args.get('path')
        if not path:
            if not doc.hasLocation():
                raise Failure('the document has no file yet: give a path')
            doc.store()
            return f'Saved {doc.getURL()}.'
        path = inside(path)
        extension = os.path.splitext(path)[1].lstrip('.').lower()
        filter_ = FILTERS.get((what, extension))
        if not filter_:
            raise Failure(f'no {extension or "unknown"} format for a {what} document; use one of '
                          + ', '.join(e for k, e in FILTERS if k == what))
        url = uno.systemPathToFileUrl(path)
        props = (prop('FilterName', filter_), prop('Overwrite', True))
        if filter_.endswith('_pdf_Export') or (what == 'spreadsheet' and extension == 'csv'):
            doc.storeToURL(url, props)
        else:
            doc.storeAsURL(url, props)
        return f'Saved as {path}.'
    raise Failure(f'no tool {name}')


# --- Chromium through the Caboose WebMCP extension ---------------------------------------------

def browser_socket(pid):
    runtime = os.environ.get('XDG_RUNTIME_DIR') or f'/run/user/{os.getuid()}'
    path = os.path.join(runtime, 'caboose-webmcp', f'{pid}.sock')
    return path if pid and os.path.exists(path) else None


def browser_tools(window):
    if not browser_socket(window.get('pid')):
        return {}
    return {
        'browser.tabs': ({}, 'The open tabs: index, title, URL, which is active', ('browser',)),
        'browser.activate': ({'index': 'integer'}, 'Switch to a tab', ('browser',)),
        'browser.open': ({'url': 'string', 'new_tab?': 'boolean'}, 'Go to a URL in the active tab, or a new one', ('browser',)),
        'browser.evaluate': ({'expression': 'string'}, "Run JavaScript in the active tab's page and return its JSON value", ('browser',)),
    }


def browser_call(window, name, args):
    path = browser_socket(window.get('pid'))
    request = {'op': 'browser', 'name': name.split('.', 1)[1], 'args': args}
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
        conn.settimeout(30)
        conn.connect(path)
        conn.sendall((json.dumps(request) + '\n').encode())
        data = b''
        while not data.endswith(b'\n'):
            chunk = conn.recv(65536)
            if not chunk:
                break
            data += chunk
    reply = json.loads(data or b'{}')
    if not reply.get('ok'):
        raise Failure(reply.get('error') or 'the browser did not answer')
    result = reply.get('result')
    return (result if isinstance(result, str) else json.dumps(result))[:MAX_READ]


# --- Requests ----------------------------------------------------------------------------------

def tools_for(window):
    tools = {}
    names = []
    try:
        names = names_of(window.get('pid'), window.get('app_id'))
    except Exception:
        pass
    for group in (lambda: gtk_actions(names), lambda: kde_actions(names), lambda: desktop_actions(window), lambda: media_tools(names), lambda: folder_tools(names),
                  lambda: settings_tools(window), lambda: office_tools(window), lambda: browser_tools(window),
                  lambda: chooser_tools(window)):
        try:
            tools.update(group())
        except Exception:
            continue
    return tools


def call(window, name, args):
    if name in FILES:
        return FILES[name][2](args)
    if name in ('settings.get', 'settings.set'):
        if not settings_tools(window):
            raise Failure('this application has no settings to offer')
        return settings_get(window, args) if name == 'settings.get' else settings_set(window, args)
    if name.startswith('doc.'):
        return office_call(window, name, args)
    if name.startswith('chooser.'):
        return chooser_call(window, name, args)
    if name.startswith('browser.'):
        if not browser_socket(window.get('pid')):
            raise Failure('the focused window is not a browser with the Caboose WebMCP extension')
        return browser_call(window, name, args)
    tools = tools_for(window)
    if name not in tools:
        raise Failure(f'no direct tool {name} for the focused window; look lists them')
    spec = tools[name][2]
    if spec[0] == 'gtk':
        return gtk_call(spec, args)
    if spec[0] == 'desktop':
        return desktop_call(spec, args)
    if spec[0] == 'kde':
        return kde_call(spec, args)
    if spec[0] == 'mpris':
        return media_call(spec, args)
    if spec[0] == 'fm':
        return folder_call(spec, args)
    raise Failure(f'no direct tool {name}')


# --- Where the window works ------------------------------------------------------------------

def where(window):
    """The files and folders the focused window's application works on, so an agent need not
    guess paths: its document (LibreOffice through UNO), the existing paths on its command line,
    a file of those folders that its title names, and its working folder. Paths, most specific
    first, without duplicates."""
    pid = window.get('pid')
    found = []

    def add(path):
        if path and os.path.exists(path):
            real = os.path.realpath(path)
            if real not in found and real != '/':
                found.append(real)
    if pid and is_office(pid):
        try:
            import uno
            url = document(window).getURL()
            if url:
                add(uno.fileUrlToSystemPath(url))
        except Exception:
            pass
    try:
        cwd = os.readlink(f'/proc/{pid}/cwd')
    except (OSError, TypeError):
        cwd = None
    try:
        with open(f'/proc/{pid}/cmdline', 'rb') as f:
            raw = f.read().rstrip(b'\0')
        # A process that retitles itself (Electron) leaves its arguments as one string.
        parts = raw.split(b'\0') if b'\0' in raw else raw.split(b' ')
        args = [a.decode('utf-8', 'replace') for a in parts[1:] if a]
    except (OSError, TypeError):
        args = []
    for arg in args:
        value = arg.split('=', 1)[1] if arg.startswith('--') and '=' in arg else arg
        if value.startswith('file://'):
            value = value[len('file://'):]
        if value.startswith('-') or not value or len(value) > 4096:
            continue
        if value.startswith('/') or (cwd and os.path.exists(os.path.join(cwd, value))):
            candidate = value if value.startswith('/') else os.path.join(cwd, value)
            # Options' own directories (profiles, extensions, sockets) are not the work.
            if arg.startswith('--') or not os.path.exists(candidate):
                continue
            add(candidate)
    title = window.get('title') or ''
    for folder in [p for p in found if os.path.isdir(p)][:3]:
        try:
            names = os.listdir(folder)[:2000]
        except OSError:
            continue
        for name in names:
            if len(name) > 3 and name in title:
                add(os.path.join(folder, name))
    if cwd and cwd.startswith(home() + os.sep):
        add(cwd)
    # What the title names first (a document, a project folder), then the rest in order.
    named = [p for p in found if os.path.basename(p) and os.path.basename(p) in title]
    return (named + [p for p in found if p not in named])[:4]


def listing(window):
    return [{'name': name, 'params': params, 'description': description} for name, (params, description, _) in tools_for(window).items()]


def serve():
    for line in sys.stdin:
        try:
            request = json.loads(line)
            window = request.get('window') or {}
            if request.get('op') == 'list':
                reply = {'tools': listing(window)}
            elif request.get('op') == 'call':
                args = request.get('args') or {}
                if not isinstance(args, dict):
                    raise Failure('args must be an object')
                reply = {'result': call(window, str(request.get('name')), args)}
            elif request.get('op') == 'where':
                reply = {'paths': where(window)}
            elif request.get('op') == 'files':
                reply = {'tools': [{'name': n, 'params': p, 'description': d} for n, (p, d, _) in FILES.items()]}
            else:
                raise Failure('op must be list, call or files')
        except Failure as error:
            reply = {'error': str(error)}
        except Exception as error:  # a library failure still answers in JSON
            reply = {'error': f'{type(error).__name__}: {error}'}
        sys.stdout.write(json.dumps(reply, ensure_ascii=False) + '\n')
        sys.stdout.flush()


if __name__ == '__main__':
    if sys.argv[1:] == ['serve']:
        serve()
    else:
        sys.exit(__doc__)
