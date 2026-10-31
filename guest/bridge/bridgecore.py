"""Shared, D-Bus-free logic for caboose-bridge and caboose-portal (docs/native-bridge.md).

Everything that crosses the guest boundary is validated here: requests the portal writes,
answers and appearance the host passes in, and the player state the daemon publishes.
"""
import hashlib
import json
import os
import pathlib
import re
import shlex
import tempfile
import time

HOME = pathlib.Path('/home/caboose')
CACHE = HOME / '.cache/caboose'
ROOT = CACHE / 'bridge'
REQUESTS = ROOT / 'requests'
CLAIMED = ROOT / 'claimed'
RESPONSES = ROOT / 'responses'
CANCELS = ROOT / 'cancels'
PRESENT = ROOT / 'present'
APPEARANCE = ROOT / 'appearance.json'
DAEMON_PID = ROOT / 'daemon.pid'
NOW_PLAYING = CACHE / 'now-playing.json'
NOW_PLAYING_COMMAND = CACHE / 'now-playing-command.json'
OWNER_BUS = 'unix:path=/run/user/1000/bus'
OWNER_ENV = pathlib.Path('/run/caboose/display.env')
AGENT_ENV = pathlib.Path('/run/caboose/agent-display.env')

ID = re.compile(r'^[0-9a-f]{32}$')
PLAYER_ID = re.compile(r'^[A-Za-z0-9._-]{1,64}$')
MIME = re.compile(r'^[A-Za-z0-9!#$&^_.+-]{1,127}/(?:\*|[A-Za-z0-9!#$&^_.+-]{1,127})$')
CONTROL = re.compile(r'[\x00-\x1f\x7f-\x9f]')
PRESENT_SECONDS = 3
CLAIM_SECONDS = 3
ABSENT_SECONDS = 10
EXPIRE_SECONDS = 86400
MAX_DRAIN = 16
MAX_LIST = 32
MAX_PATHS = 64

DEFAULT_APPEARANCE = {'colorScheme': 'dark', 'accent': '#0A84FF', 'contrast': 'normal', 'reducedMotion': False, 'textScale': 1.0}


class Invalid(ValueError):
    pass


def prepare():
    for d in (ROOT, REQUESTS, CLAIMED, RESPONSES, CANCELS):
        d.mkdir(parents=True, exist_ok=True, mode=0o700)


def write_json(path, value):
    """Atomically replaces `path`, private to the owner."""
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, temporary = tempfile.mkstemp(prefix='.' + path.name + '.', dir=path.parent)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as out:
            json.dump(value, out, separators=(',', ':'), ensure_ascii=True)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def read_json(path, limit=65536):
    try:
        with open(path, 'rb') as f:
            data = f.read(limit + 1)
    except OSError:
        return None
    if len(data) > limit:
        return None
    try:
        return json.loads(data)
    except ValueError:
        return None


def expire(now=None):
    """Removes bridge files older than a day: requests nobody claimed, answers nobody read."""
    now = time.time() if now is None else now
    for d in (REQUESTS, CLAIMED, RESPONSES, CANCELS):
        try:
            entries = list(d.iterdir())
        except FileNotFoundError:
            continue
        for f in entries:
            try:
                if now - f.stat().st_mtime > EXPIRE_SECONDS:
                    f.unlink()
            except FileNotFoundError:
                pass


def present(now=None):
    """The phone is present while the host drained within the last 3 seconds."""
    now = time.time() if now is None else now
    try:
        return now - PRESENT.stat().st_mtime < PRESENT_SECONDS
    except FileNotFoundError:
        return False


# Requests ---------------------------------------------------------------------------------

def text(value, limit):
    return isinstance(value, str) and len(value) <= limit and not CONTROL.search(value)


def clean(value, limit):
    """A display string from an untrusted source: control characters removed, bounded."""
    return CONTROL.sub('', str(value))[:limit]


def home_path(value, allow_home=False):
    if not isinstance(value, str) or CONTROL.search(value) or len(value.encode()) > 4096:
        return False
    if value == str(HOME):
        return allow_home
    if not value.startswith(str(HOME) + '/'):
        return False
    return all(part not in ('', '.', '..') for part in value[len(str(HOME)) + 1:].split('/'))


def portal_filters(filters, current=None):
    """Portal filters a(sa(us)) (0 = glob, 1 = MIME type) as request filters, and the index
    of `current`, which is added when the list does not contain it."""
    result = []
    for name, rules in (filters or [])[:MAX_LIST]:
        patterns = [str(p) for kind, p in rules if kind == 0 and p and text(str(p), 255)][:MAX_LIST]
        mimes = [str(p) for kind, p in rules if kind == 1 and MIME.match(str(p))][:MAX_LIST]
        result.append({'name': clean(name, 100), 'patterns': patterns, 'mimeTypes': mimes})
    index = None
    if current is not None:
        name, rules = current
        wanted = {'name': clean(name, 100),
                  'patterns': [str(p) for kind, p in rules if kind == 0 and p and text(str(p), 255)][:MAX_LIST],
                  'mimeTypes': [str(p) for kind, p in rules if kind == 1 and MIME.match(str(p))][:MAX_LIST]}
        if wanted in result:
            index = result.index(wanted)
        elif len(result) < MAX_LIST:
            result.append(wanted)
            index = len(result) - 1
    return result, index


def portal_path(value):
    """A portal `ay` path (NUL-terminated bytes) as a string, or ''."""
    if not value:
        return ''
    raw = bytes(value).rstrip(b'\0')
    try:
        return raw.decode()
    except UnicodeDecodeError:
        return ''


def new_request(kind, app, title, options, now=None):
    """The request the portal writes for OpenFile or SaveFile, from the portal's options."""
    filters, current = portal_filters(options.get('filters'), options.get('current_filter'))
    folder = portal_path(options.get('current_folder'))
    name = clean(options.get('current_name', ''), 255) if kind == 'file.save' else ''
    current_file = portal_path(options.get('current_file'))
    if kind == 'file.save' and current_file and home_path(current_file):
        folder = folder or str(pathlib.PurePosixPath(current_file).parent)
        name = name or pathlib.PurePosixPath(current_file).name
    name = name.replace('/', '')
    if name in ('.', '..'):
        name = ''
    while len(name.encode()) > 255:
        name = name[:-1]
    return {
        'id': os.urandom(16).hex(),
        'type': kind,
        'app': clean(app, 200),
        'title': clean(title, 200),
        'acceptLabel': clean(options.get('accept_label', ''), 64),
        'multiple': kind == 'file.open' and bool(options.get('multiple', False)),
        'directory': kind == 'file.open' and bool(options.get('directory', False)),
        'filters': filters,
        'currentFilter': current,
        'currentName': name,
        'currentFolder': folder if home_path(folder, allow_home=True) else '',
        'created': int(time.time() if now is None else now),
    }


# The two formats `caboose-scan` asks for, each as a request's only filter: a PDF is one
# file; JPEG is one image per page.
SCAN_FORMATS = {
    'pdf': ({'name': 'PDF', 'patterns': ['*.pdf'], 'mimeTypes': ['application/pdf']}, False),
    'jpeg': ({'name': 'JPEG', 'patterns': ['*.jpg', '*.jpeg'], 'mimeTypes': ['image/jpeg']}, True),
}


def new_scan_request(fmt, now=None):
    """The request `caboose-scan` writes: scan a document with the phone, as `fmt`."""
    filter_, multiple = SCAN_FORMATS[fmt]
    return {
        'id': os.urandom(16).hex(),
        'type': 'scan',
        'app': '',
        'title': '',
        'acceptLabel': '',
        'multiple': multiple,
        'directory': False,
        'filters': [{**filter_, 'patterns': list(filter_['patterns']), 'mimeTypes': list(filter_['mimeTypes'])}],
        'currentFilter': 0,
        'currentName': '',
        'currentFolder': '',
        'created': int(time.time() if now is None else now),
    }


def withdraw(ident):
    """Takes back a request: unclaimed, it is simply gone; claimed, the host is told
    (`bridge/cancels/<id>`) so the phone takes down what it shows for it."""
    (REQUESTS / f'{ident}.json').unlink(missing_ok=True)
    claimed = CLAIMED / f'{ident}.json'
    if claimed.exists():
        claimed.unlink(missing_ok=True)
        prepare()
        (CANCELS / ident).touch(mode=0o600)


def check_answer(answer, request=None):
    """An answer the host passes to `respond`, validated again: the guest trusts no input."""
    if not isinstance(answer, dict) or not isinstance(answer.get('id'), str) or not ID.match(answer['id']):
        raise Invalid('answer needs a request id')
    response = answer.get('response')
    if response in ('cancel', 'computer'):
        if set(answer) != {'id', 'response'}:
            raise Invalid('unexpected answer fields')
        return {'id': answer['id'], 'response': response}
    if response != 'ok' or not set(answer) <= {'id', 'response', 'paths', 'filter'}:
        raise Invalid('response must be ok, cancel or computer')
    paths = answer.get('paths')
    if not isinstance(paths, list) or not 1 <= len(paths) <= MAX_PATHS or not all(home_path(p) for p in paths) or len(set(paths)) != len(paths):
        raise Invalid('paths must be 1 to 64 distinct paths under /home/caboose')
    flt = answer.get('filter')
    if flt is not None and (not isinstance(flt, int) or isinstance(flt, bool) or flt < 0):
        raise Invalid('filter must be an index')
    if request is not None:
        if (request['type'] == 'file.save' or not request['multiple']) and len(paths) != 1:
            raise Invalid('this request takes one path')
        if flt is not None and flt >= len(request['filters']):
            raise Invalid('filter is not one of the request\'s')
    return {'id': answer['id'], 'response': 'ok', 'paths': paths, 'filter': flt}


def chosen(request, answer, exists=os.path.exists, isdir=os.path.isdir):
    """The paths of an `ok` answer as the portal returns them, or None when they cannot be:
    an open or a scan names existing files (folders when choosing one); a save names a file
    whose folder exists."""
    paths = answer['paths']
    if request['type'] != 'file.save':
        for p in paths:
            if not exists(p) or isdir(p) != request.get('directory', False):
                return None
    else:
        p = paths[0]
        if not isdir(os.path.dirname(p)) or isdir(p):
            return None
    return paths


def scan_output_problem(output, fmt, exists=os.path.exists, isdir=os.path.isdir):
    """Why `caboose-scan --output` cannot be used, or None. A PDF goes into a folder that
    exists, or to a file in one; JPEG pages go into a folder, made when missing."""
    parent = os.path.dirname(os.path.abspath(output))
    if isdir(output):
        return None
    if fmt == 'jpeg' and exists(output):
        return f'{output} is not a folder; JPEG pages are saved in a folder'
    if not isdir(parent):
        return f'{parent} does not exist'
    return None


def scan_destinations(paths, output, fmt, isdir=os.path.isdir):
    """Where each scanned file moves for `--output`: into it when it is a folder (JPEG pages
    always are), else to it."""
    if fmt == 'pdf' and not isdir(output):
        return [(paths[0], output)]
    return [(p, os.path.join(output, os.path.basename(p))) for p in paths]


# Appearance -------------------------------------------------------------------------------

def check_appearance(value):
    if not isinstance(value, dict) or set(value) != set(DEFAULT_APPEARANCE):
        raise Invalid('appearance needs exactly colorScheme, accent, contrast, reducedMotion and textScale')
    if value['colorScheme'] not in ('light', 'dark'):
        raise Invalid('colorScheme must be light or dark')
    if not isinstance(value['accent'], str) or not re.fullmatch(r'#[0-9A-Fa-f]{6}', value['accent']):
        raise Invalid('accent must be #RRGGBB')
    if value['contrast'] not in ('normal', 'high'):
        raise Invalid('contrast must be normal or high')
    if not isinstance(value['reducedMotion'], bool):
        raise Invalid('reducedMotion must be a boolean')
    scale = value['textScale']
    if isinstance(scale, bool) or not isinstance(scale, (int, float)) or not 0.75 <= scale <= 2:
        raise Invalid('textScale must be from 0.75 to 2')
    return {**value, 'accent': value['accent'].upper(), 'textScale': float(scale)}


def appearance():
    """The appearance last received, or the image's own (dark) when there is none."""
    try:
        return check_appearance(read_json(APPEARANCE))
    except Invalid:
        return dict(DEFAULT_APPEARANCE)


def rgb(accent):
    return tuple(int(accent[i:i + 2], 16) / 255 for i in (1, 3, 5))


# GNOME's named accents (org.gnome.desktop.interface accent-color), each with the iOS
# system colours (light and dark appearance) it corresponds to: the phone's accent is
# almost always one of these.
ACCENTS = {
    'blue': ('#007AFF', '#0A84FF'), 'teal': ('#30B0C7', '#40C8E0', '#5AC8FA', '#64D2FF', '#00C7BE', '#63E6E2'),
    'green': ('#34C759', '#30D158'), 'yellow': ('#FFCC00', '#FFD60A'), 'orange': ('#FF9500', '#FF9F0A'),
    'red': ('#FF3B30', '#FF453A'), 'pink': ('#FF2D55', '#FF375F'), 'purple': ('#AF52DE', '#BF5AF2', '#5856D6', '#5E5CE6'),
}


def named_accent(accent):
    """The GNOME accent nearest to `accent`; slate for greys."""
    import colorsys
    color = rgb(accent)
    if colorsys.rgb_to_hls(*color)[2] < 0.2:
        return 'slate'
    distance = lambda value: sum((a - b) ** 2 for a, b in zip(color, rgb(value)))
    return min(((distance(v), name) for name, values in ACCENTS.items() for v in values))[1]


def themes(look, available):
    """GTK, icon and cursor themes for `look`: the image's WhiteSur in the phone's scheme,
    or Adwaita when that variant is not installed."""
    dark = look['colorScheme'] == 'dark'
    gtk = 'WhiteSur-Dark' if dark else 'WhiteSur-Light'
    if gtk not in available:
        gtk = 'Adwaita-dark' if dark else 'Adwaita'
    icons = 'WhiteSur-dark' if dark else 'WhiteSur'
    return {'gtk': gtk, 'icons': icons, 'cursor': 'WhiteSur-cursors'}


def interface_settings(look, available):
    """org.gnome.desktop.interface as GTK reads it through the Settings portal."""
    t = themes(look, available)
    return {
        'gtk-theme': ('s', t['gtk']),
        'icon-theme': ('s', t['icons']),
        'cursor-theme': ('s', t['cursor']),
        'cursor-size': ('i', 24),
        'font-name': ('s', 'Inter 10'),
        'monospace-font-name': ('s', 'JetBrains Mono 10'),
        'color-scheme': ('s', 'prefer-dark' if look['colorScheme'] == 'dark' else 'default'),
        'accent-color': ('s', named_accent(look['accent'])),
        'text-scaling-factor': ('d', look['textScale']),
        'enable-animations': ('b', not look['reducedMotion']),
        'gtk-enable-primary-paste': ('b', True),
        'font-antialiasing': ('s', 'grayscale'),
        'font-hinting': ('s', 'slight'),
    }


def appearance_settings(look):
    """org.freedesktop.appearance."""
    return {
        'color-scheme': ('u', 1 if look['colorScheme'] == 'dark' else 2),
        'accent-color': ('(ddd)', rgb(look['accent'])),
        'contrast': ('u', 1 if look['contrast'] == 'high' else 0),
        'reduced-motion': ('u', 1 if look['reducedMotion'] else 0),
    }


def settings_ini(existing, look, available):
    """A GTK settings.ini with the theme keys for `look`, other keys kept."""
    t = themes(look, available)
    wanted = {
        'gtk-theme-name': t['gtk'],
        'gtk-icon-theme-name': t['icons'],
        'gtk-application-prefer-dark-theme': '1' if look['colorScheme'] == 'dark' else '0',
        'gtk-enable-animations': '0' if look['reducedMotion'] else '1',
    }
    lines, seen, in_settings = [], set(), False
    for line in (existing or '[Settings]\n').splitlines():
        stripped = line.strip()
        if stripped.startswith('['):
            if in_settings:
                lines.extend(f'{k}={v}' for k, v in wanted.items() if k not in seen)
                seen.update(wanted)
            in_settings = stripped == '[Settings]'
        elif in_settings and '=' in stripped:
            key = stripped.split('=', 1)[0].strip()
            if key in wanted:
                lines.append(f'{key}={wanted[key]}')
                seen.add(key)
                continue
        lines.append(line)
    if not any(l.strip() == '[Settings]' for l in lines):
        lines.append('[Settings]')
        in_settings = True
    if in_settings:
        lines.extend(f'{k}={v}' for k, v in wanted.items() if k not in seen)
    return '\n'.join(lines) + '\n'


# Now playing ------------------------------------------------------------------------------

def https(value):
    if not isinstance(value, str) or len(value) > 4096 or re.search(r'[\x00-\x20\x7f]', value):
        return None
    return value if value.startswith('https://') and len(value) > len('https://') else None


def pick_player(players):
    """The player to show: the one most recently playing; with none playing, the one most
    recently paused. `players` maps a name to {status, playedAt, pausedAt}."""
    playing = [(p['playedAt'], n) for n, p in players.items() if p['status'] == 'Playing']
    if playing:
        return max(playing)[1]
    paused = [(max(p['playedAt'], p['pausedAt']), n) for n, p in players.items() if p['status'] == 'Paused']
    return max(paused)[1] if paused else None


def player_key(name):
    return hashlib.sha256(name.encode()).hexdigest()[:12]


def track_state(name, generation, identity, status, metadata, position_us, rate, caps, now_ms):
    """now-playing.json for a player, from its MPRIS properties (already unpacked)."""
    length = metadata.get('mpris:length')
    duration = length / 1e6 if isinstance(length, (int, float)) and not isinstance(length, bool) and 0 < length <= 1e13 else None
    artist = metadata.get('xesam:artist')
    if isinstance(artist, (list, tuple)):
        artist = ', '.join(str(a) for a in artist)
    position = max(0.0, (position_us or 0) / 1e6)
    if duration is not None:
        position = min(position, duration)
    try:
        rate = float(rate)
    except (TypeError, ValueError):
        rate = 1.0
    return {
        'id': f'{player_key(name)}-{generation}',
        'player': clean(identity or name.rsplit('.', 1)[-1], 100),
        'title': clean(metadata.get('xesam:title', ''), 300),
        'artist': clean(artist or '', 300),
        'album': clean(metadata.get('xesam:album', ''), 300),
        'artwork': https(metadata.get('mpris:artUrl')),
        'position': round(min(position, 1e7), 3),
        'duration': round(duration, 3) if duration is not None and duration <= 1e7 else None,
        'paused': status != 'Playing',
        'rate': min(16.0, max(0.0, rate)),
        'canPlay': bool(caps.get('CanPlay')), 'canPause': bool(caps.get('CanPause')),
        'canNext': bool(caps.get('CanGoNext')), 'canPrevious': bool(caps.get('CanGoPrevious')),
        'canSeek': bool(caps.get('CanSeek')),
        'updatedAt': int(now_ms),
    }


def track_identity(metadata):
    """What makes a track a new one: its MPRIS track id, else its title, artist and album."""
    trackid = metadata.get('mpris:trackid')
    if trackid and str(trackid) != '/org/mpris/MediaPlayer2/TrackList/NoTrack':
        return str(trackid)
    return '\0'.join(str(metadata.get(k, '')) for k in ('xesam:title', 'xesam:artist', 'xesam:album', 'xesam:url'))


def check_command(value, last_seq):
    """A now-playing command to apply, or None (malformed, or a sequence already passed)."""
    if not isinstance(value, dict):
        return None
    seq, ident, action = value.get('seq'), value.get('id'), value.get('action')
    if not isinstance(seq, int) or isinstance(seq, bool) or seq <= last_seq:
        return None
    if not isinstance(ident, str) or not PLAYER_ID.match(ident):
        return None
    if action not in ('play', 'pause', 'toggle', 'next', 'previous', 'seek'):
        return None
    position = value.get('position')
    if action == 'seek':
        if isinstance(position, bool) or not isinstance(position, (int, float)) or not 0 <= position <= 1e7:
            return None
    return {'seq': seq, 'id': ident, 'action': action, 'position': position if action == 'seek' else None}


# Seat environment -------------------------------------------------------------------------

def read_env(path):
    """A launch environment file (KEY=value lines) as a dict."""
    env = {}
    try:
        lines = pathlib.Path(path).read_text(encoding='utf-8').splitlines()
    except OSError:
        return env
    for line in lines:
        if '=' in line and not line.startswith('#'):
            key, value = line.split('=', 1)
            if re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*', key):
                # caboose-display single-quotes each value for sh.
                try:
                    words = shlex.split(value)
                except ValueError:
                    continue
                env[key] = words[0] if len(words) == 1 else ''
    return env
