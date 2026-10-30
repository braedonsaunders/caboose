"""Agent apps: the logic of caboose-app that needs no display.

An agent app is a directory ~/Apps/<id>/ holding app.json and the app's web files. This
module validates the manifest, maps caboose-app:// URLs to files, writes the desktop entry
that puts the app in the Apps screen, checks bridge requests, and does the bridge's file
operations without following a symlink out of their root. Standard library only, so it is
unit-tested without GTK or WebKit.
"""
import colorsys
import errno
import hashlib
from html.parser import HTMLParser
import json
import mimetypes
import os
import re
import secrets
import select
import shutil
import stat
import time
import urllib.parse

SCHEME = 'caboose-app'
ID = re.compile(r'[a-z][a-z0-9-]{0,47}')
MANIFEST = 'app.json'
MANIFEST_LIMIT = 64 * 1024
CAPABILITIES = ('exec', 'files', 'notify', 'open', 'net')
# The Desktop Menu Specification's main categories.
CATEGORIES = ('AudioVideo', 'Audio', 'Video', 'Development', 'Education', 'Game', 'Graphics',
              'Network', 'Office', 'Science', 'Settings', 'System', 'Utility')
COLOR = re.compile(r'#[0-9a-fA-F]{6}')
ICON_TYPES = ('.svg', '.png')
ENTRY_TYPES = ('.html', '.htm')
WINDOW_LIMITS = {'width': (320, 3840), 'height': (240, 2160), 'minWidth': (200, 3840), 'minHeight': (200, 2160)}
DEFAULT_WINDOW = {'width': 1024, 'height': 720}

# Scripts run only from the app's own files: no inline scripts or handler attributes, no
# eval, no blob: or data: scripts, so nothing fetched at run time becomes script that can
# reach the bridge. WebAssembly may compile. Data may come from anywhere. Frames hold the
# app's own pages, never remote ones. The scheme handler serves only the app's own id, so
# 'caboose-app:' allows nothing beyond 'self'; it covers an engine whose 'self' does not
# match a custom scheme. The runtime sends this as a header and as a <meta> element in
# every HTML page.
CSP = ("default-src 'self' caboose-app:; "
       "script-src 'self' caboose-app: 'wasm-unsafe-eval'; "
       "style-src 'self' caboose-app: 'unsafe-inline' blob: data: https:; "
       "font-src 'self' caboose-app: blob: data: https:; "
       "img-src * blob: data:; media-src * blob: data:; connect-src *; "
       "worker-src 'self' caboose-app:; frame-src 'self' caboose-app:; "
       "object-src 'none'; base-uri 'self'; form-action 'self'")
# Script types a browser runs; a script of any other type is a data block.
SCRIPT_TYPES = ('', 'module', 'importmap', 'text/javascript', 'application/javascript', 'text/ecmascript',
                'application/ecmascript', 'javascript')
MAX_PAGES = 500
MAX_PAGE = 4 * 1024 * 1024

# Bridge bounds.
MAX_ARGS = 256
MAX_ARG = 128 * 1024
MAX_ARGV = 1024 * 1024
MAX_ENV = 64
MAX_ENV_VALUE = 32 * 1024
ENV_NAME = re.compile(r'[A-Za-z_][A-Za-z0-9_]{0,127}')
MAX_STDIN = 16 * 1024 * 1024
MAX_OUTPUT = 16 * 1024 * 1024
DEFAULT_TIMEOUT_MS = 60_000
MAX_TIMEOUT_MS = 600_000
MAX_RUNNING = 16
# How long process.write waits for a spawned program to take its input.
WRITE_TIMEOUT_S = 30
MAX_FILE = 64 * 1024 * 1024
MAX_LIST = 10_000
EXTERNAL_SCHEMES = ('http', 'https', 'mailto', 'tel', 'sms')

mimetypes.add_type('text/javascript', '.js')
mimetypes.add_type('text/javascript', '.mjs')
mimetypes.add_type('application/wasm', '.wasm')
mimetypes.add_type('image/svg+xml', '.svg')
mimetypes.add_type('application/json', '.json')
mimetypes.add_type('font/woff2', '.woff2')
mimetypes.add_type('font/woff', '.woff')


class AppError(ValueError):
    """A refusal with a sentence for the app's author."""


def bridge_request(request, methods, capabilities):
    """Validate a bridge request and dispatch it under the app's startup capabilities.

    Authentication and document lifetime are the transport's responsibility. The method
    table is supplied by the runtime, never by the caller.
    """
    if not isinstance(request, dict):
        raise AppError('Malformed request')
    method, params = request.get('method'), request.get('params')
    if not isinstance(method, str) or method not in methods or not isinstance(params, dict):
        raise AppError(f'Unknown method {str(method)[:60]}')
    capability, handler = methods[method]
    if capability not in capabilities:
        raise AppError(f'This app does not declare the "{capability}" capability in app.json; '
                       'add it and start the app again')
    return handler(params)


class Places:
    """Where one home keeps agent apps, their data and their desktop entries."""

    def __init__(self, home):
        self.home = os.path.realpath(home)
        self.apps = os.path.join(self.home, 'Apps')
        self.data = os.path.join(self.home, '.local', 'share', 'caboose', 'apps')
        self.cache = os.path.join(self.home, '.cache', 'caboose', 'apps')
        self.entries = os.path.join(self.home, '.local', 'share', 'applications')

    def app(self, ident):
        return os.path.join(self.apps, check_id(ident))

    def app_data(self, ident):
        return os.path.join(self.data, check_id(ident))

    def files(self, ident):
        return os.path.join(self.app_data(ident), 'files')

    def web(self, ident):
        return os.path.join(self.app_data(ident), 'web')

    def web_cache(self, ident):
        return os.path.join(self.cache, check_id(ident))

    def log(self, ident):
        return os.path.join(self.app_data(ident), 'console.log')

    def entry(self, ident):
        return os.path.join(self.entries, f'{application_id(ident)}.desktop')


def check_id(ident):
    if not isinstance(ident, str) or not ID.fullmatch(ident):
        raise AppError('An app id is a lowercase letter followed by up to 47 lowercase letters, digits or hyphens')
    return ident


def application_id(ident):
    """The GApplication id, Wayland app_id, X11 class and desktop entry name of an app."""
    return f'caboose.app.{check_id(ident)}'


def _text(value, name, limit, errors, required=False):
    if value is None:
        if required:
            errors.append(f'{name} is required')
        return None
    if not isinstance(value, str) or not value.strip():
        errors.append(f'{name} must be a non-empty string')
        return None
    value = value.strip()
    if len(value) > limit:
        errors.append(f'{name} must be at most {limit} characters')
        return None
    if any(ord(c) < 32 or ord(c) == 127 for c in value):
        errors.append(f'{name} must not contain control characters')
        return None
    return value


def _relative(value, name, suffixes, errors):
    """A path inside the app directory: relative, '/'-separated, no '.' or '..' parts."""
    if not isinstance(value, str) or not value:
        errors.append(f'{name} must be a path inside the app directory')
        return None
    parts = value.split('/')
    if value.startswith('/') or '\\' in value or '\0' in value or any(p in ('', '.', '..') for p in parts):
        errors.append(f'{name} must be a relative path inside the app directory, without "." or ".." parts')
        return None
    if not value.lower().endswith(suffixes):
        errors.append(f'{name} must end in {" or ".join(suffixes)}')
        return None
    return value


def inside(root, path):
    """True when path, with every symlink resolved, is root or below it."""
    root = os.path.realpath(root)
    path = os.path.realpath(path)
    return path == root or path.startswith(root + os.sep)


def load_manifest(app_dir):
    """Reads and validates app.json. Returns (manifest, errors); manifest is None on errors."""
    errors = []
    path = os.path.join(app_dir, MANIFEST)
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    except FileNotFoundError:
        return None, [f'{MANIFEST} is missing']
    except OSError as error:
        return None, [f'{MANIFEST} could not be read: {error.strerror}']
    with os.fdopen(fd, 'rb') as handle:
        raw = handle.read(MANIFEST_LIMIT + 1)
    if len(raw) > MANIFEST_LIMIT:
        return None, [f'{MANIFEST} must be at most {MANIFEST_LIMIT} bytes']
    try:
        data = json.loads(raw.decode('utf-8'))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        return None, [f'{MANIFEST} is not valid JSON: {error}']
    if not isinstance(data, dict):
        return None, [f'{MANIFEST} must be a JSON object']
    known = {'name', 'description', 'version', 'entry', 'icon', 'categories', 'capabilities', 'window', 'handoff'}
    for key in sorted(set(data) - known):
        errors.append(f'Unknown field "{key}"; the fields are {", ".join(sorted(known))}')
    manifest = {
        'name': _text(data.get('name'), 'name', 60, errors, required=True),
        'description': _text(data.get('description'), 'description', 300, errors) or '',
        'version': _text(data.get('version'), 'version', 32, errors) or '',
        'entry': _relative(data.get('entry', 'index.html'), 'entry', ENTRY_TYPES, errors),
        'icon': None,
        'categories': ['Utility'],
        'capabilities': [],
        'handoff': None,
        'window': dict(DEFAULT_WINDOW),
    }
    if 'handoff' in data:
        if data['handoff'] != 'files':
            errors.append('handoff must be "files"')
        else:
            manifest['handoff'] = 'files'
    if 'icon' in data:
        manifest['icon'] = _relative(data['icon'], 'icon', ICON_TYPES, errors)
    for key, allowed in (('categories', CATEGORIES), ('capabilities', CAPABILITIES)):
        if key not in data:
            continue
        value = data[key]
        if not isinstance(value, list) or not all(isinstance(v, str) for v in value) or len(value) > len(allowed):
            errors.append(f'{key} must be a list of: {", ".join(allowed)}')
            continue
        unknown = [v for v in value if v not in allowed]
        if unknown:
            errors.append(f'{key} has unknown {", ".join(unknown)}; choose from {", ".join(allowed)}')
            continue
        manifest[key] = list(dict.fromkeys(value))
    if not manifest['categories']:
        manifest['categories'] = ['Utility']
    window = data.get('window', {})
    if not isinstance(window, dict):
        errors.append('window must be an object')
        window = {}
    for key in sorted(set(window) - set(WINDOW_LIMITS) - {'background'}):
        errors.append(f'Unknown window field "{key}"; the fields are width, height, minWidth, minHeight, background')
    for key, (low, high) in WINDOW_LIMITS.items():
        if key not in window:
            continue
        value = window[key]
        if not isinstance(value, int) or isinstance(value, bool) or not low <= value <= high:
            errors.append(f'window.{key} must be an integer from {low} to {high}')
        else:
            manifest['window'][key] = value
    if 'background' in window:
        if not isinstance(window['background'], str) or not COLOR.fullmatch(window['background']):
            errors.append('window.background must be a colour like "#101418"')
        else:
            manifest['window']['background'] = window['background'].lower()
    for name in ('entry', 'icon'):
        relative = manifest[name]
        if relative is None:
            continue
        target = os.path.join(app_dir, relative)
        if not inside(app_dir, target):
            errors.append(f'{name} leaves the app directory through a symbolic link')
        elif not os.path.isfile(target):
            errors.append(f'{name} "{relative}" is not a file in the app directory')
    if errors:
        return None, errors
    return manifest, []


def resource_path(app_dir, ident, uri, entry):
    """The file a caboose-app:// URL names, or None. The host must be the app's id; the
    percent-decoded path may not contain '.' or '..' parts or leave the directory through a
    symbolic link. A directory serves its index.html; the root serves the manifest's entry."""
    try:
        parts = urllib.parse.urlsplit(uri)
    except ValueError:
        return None
    if parts.scheme != SCHEME or parts.netloc != ident:
        return None
    raw = parts.path or '/'
    if '%2f' in raw.lower() or '%5c' in raw.lower():
        return None
    try:
        path = urllib.parse.unquote(raw, errors='strict')
    except UnicodeDecodeError:
        return None
    if '\0' in path or '\\' in path or not path.startswith('/'):
        return None
    pieces = path[1:].split('/') if path != '/' else []
    directory = bool(pieces) and pieces[-1] == ''
    if directory:
        pieces = pieces[:-1]
    if any(p in ('', '.', '..') for p in pieces):
        return None
    if not pieces:
        pieces = entry.split('/')
    elif directory:
        pieces.append('index.html')
    target = os.path.join(app_dir, *pieces)
    if os.path.isdir(target):
        target = os.path.join(target, 'index.html')
    if not inside(app_dir, target) or not os.path.isfile(target):
        return None
    return os.path.realpath(target)


def app_url(ident, relative=''):
    return f'{SCHEME}://{check_id(ident)}/{urllib.parse.quote(relative)}'


def content_type(path):
    kind, encoding = mimetypes.guess_type(path)
    if encoding or not kind:
        return 'application/octet-stream'
    if kind.startswith('text/') or kind in ('application/json', 'image/svg+xml'):
        return f'{kind}; charset=utf-8'
    return kind


_HEAD = re.compile(rb'<head(\s[^>]*)?>', re.IGNORECASE)
_DOCTYPE = re.compile(rb'\s*<!doctype[^>]*>', re.IGNORECASE)


def with_csp(html):
    """The page with the policy as its first <head> element, so it holds even where a
    custom scheme's response headers are not applied. A page without <head> gets it after
    its doctype, which keeps the page out of quirks mode."""
    meta = f'<meta http-equiv="Content-Security-Policy" content="{CSP}">'.encode()
    match = _HEAD.search(html, 0, 64 * 1024)
    if match:
        return html[:match.end()] + meta + html[match.end():]
    match = _DOCTYPE.match(html)
    at = match.end() if match else 0
    return html[:at] + meta + html[at:]


def is_app_url(uri, ident):
    try:
        parts = urllib.parse.urlsplit(uri)
    except ValueError:
        return False
    return parts.scheme == SCHEME and parts.netloc == ident


def external_url(uri):
    """The URL if the default handler may open it (web links, mail, phone), else None."""
    try:
        parts = urllib.parse.urlsplit(uri)
    except ValueError:
        return None
    if parts.scheme not in EXTERNAL_SCHEMES:
        return None
    if parts.scheme in ('http', 'https') and not parts.hostname:
        return None
    if any(ord(c) < 32 for c in uri) or len(uri) > 8192:
        return None
    return uri


def _desktop_value(value):
    return value.replace('\\', '\\\\').replace('\n', '\\n').replace('\t', '\\t').replace('\r', '\\r')


def desktop_entry(ident, manifest, icon, runtime='/usr/local/bin/caboose-app'):
    """The desktop entry that lists the app in the Apps screen and starts it."""
    lines = [
        '[Desktop Entry]',
        'Type=Application',
        f'Name={_desktop_value(manifest["name"])}',
    ]
    if manifest['description']:
        lines.append(f'Comment={_desktop_value(manifest["description"])}')
    lines += [
        f'Exec={runtime} run {check_id(ident)}',
        f'Icon={_desktop_value(icon)}',
        'Terminal=false',
        f'Categories={";".join(manifest["categories"])};',
        f'StartupWMClass={application_id(ident)}',
        f'X-Caboose-App={ident}',
    ]
    if manifest['version']:
        lines.append(f'X-Caboose-App-Version={_desktop_value(manifest["version"])}')
    return '\n'.join(lines) + '\n'


def default_icon(ident, name):
    """A monogram icon in a colour derived from the id, for an app that names none."""
    hue = int.from_bytes(hashlib.sha256(ident.encode()).digest()[:2], 'big') / 65536
    def rgb(lightness, saturation):
        r, g, b = colorsys.hls_to_rgb(hue, lightness, saturation)
        return f'#{round(r * 255):02x}{round(g * 255):02x}{round(b * 255):02x}'
    letter = next((c for c in name if c.isalnum()), ident[0]).upper()
    return (
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 128 128">'
        '<defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1">'
        f'<stop offset="0" stop-color="{rgb(0.62, 0.78)}"/><stop offset="1" stop-color="{rgb(0.38, 0.72)}"/>'
        '</linearGradient></defs>'
        '<rect x="4" y="4" width="120" height="120" rx="28" fill="url(#g)"/>'
        '<text x="64" y="64" dy=".35em" text-anchor="middle" fill="#fff" '
        'font-family="Inter, sans-serif" font-weight="700" font-size="60">'
        f'{letter}</text></svg>\n'
    )


def write_atomic(path, data, mode=0o644):
    directory = os.path.dirname(path)
    os.makedirs(directory, exist_ok=True)
    temp = os.path.join(directory, f'.{os.path.basename(path)}.{secrets.token_hex(6)}')
    fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, mode)
    try:
        with os.fdopen(fd, 'wb') as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temp, path)
    except BaseException:
        try:
            os.unlink(temp)
        except FileNotFoundError:
            pass
        raise


_COMMENT = re.compile(r'<!--.*?-->', re.DOTALL)
_SCRIPT = re.compile(r'<script\b([^>]*)>(.*?)</script\s*>', re.IGNORECASE | re.DOTALL)
_TAG = re.compile(r'<[a-zA-Z][^>]*>')
_HANDLER = re.compile(r'\son[a-z]+\s*=', re.IGNORECASE)
_JS_URL = re.compile(r'''(?:href|src|action|formaction)\s*=\s*["']?\s*javascript:''', re.IGNORECASE)
_ATTR = re.compile(r'''(?:^|\s)(src|type)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+)))?''', re.IGNORECASE)


def page_problems(name, html):
    """Script in a page that the policy blocks: inline <script> elements, event handler
    attributes and javascript: URLs, each with its file and line."""
    problems = []
    text = _COMMENT.sub(lambda m: '\n' * m.group(0).count('\n'), html)

    def line(at):
        return text.count('\n', 0, at) + 1
    for match in _SCRIPT.finditer(text):
        attrs = {m.group(1).lower(): (m.group(2) or m.group(3) or m.group(4) or '') for m in _ATTR.finditer(match.group(1))}
        if 'src' not in attrs and attrs.get('type', '').strip().lower() in SCRIPT_TYPES and match.group(2).strip():
            problems.append(f'{name} line {line(match.start())}: an inline <script> does not run; move it into a .js '
                            'file in the app and load it with <script src="...">')
    for match in _TAG.finditer(text):
        if _HANDLER.search(match.group(0)):
            problems.append(f'{name} line {line(match.start())}: event handler attributes (onclick="...") do not run; '
                            'use addEventListener in a .js file')
        if _JS_URL.search(match.group(0)):
            problems.append(f'{name} line {line(match.start())}: javascript: URLs do not run; '
                            'use addEventListener in a .js file')
    return problems


def scan_pages(app_dir):
    """The page problems of every HTML file in the app."""
    problems, seen = [], 0
    for directory, dirs, files in os.walk(app_dir):
        dirs[:] = sorted(d for d in dirs if not d.startswith('.') and d != 'node_modules')
        for file in sorted(files):
            path = os.path.join(directory, file)
            if not file.lower().endswith(ENTRY_TYPES) or os.path.islink(path) or seen == MAX_PAGES:
                continue
            seen += 1
            try:
                with open(path, 'rb') as handle:
                    html = handle.read(MAX_PAGE).decode('utf-8', 'replace')
            except OSError:
                continue
            problems += page_problems(os.path.relpath(path, app_dir), html)
    return problems


def check(places, ident):
    """Validates an app. Returns {id, ok, errors, manifest?}."""
    app_dir = places.app(ident)
    if not os.path.isdir(app_dir) or os.path.islink(app_dir):
        return {'id': ident, 'ok': False, 'errors': [f'{app_dir} is not a directory']}
    manifest, errors = load_manifest(app_dir)
    errors += scan_pages(app_dir)
    if errors:
        manifest = None
    result = {'id': ident, 'ok': not errors, 'errors': errors}
    if manifest:
        result['manifest'] = manifest
        result['warnings'] = entry_input_warnings(app_dir, manifest['entry'])
    return result


class _ViewportParser(HTMLParser):
    def __init__(self):
        super().__init__()
        self.viewports = []
        self.template_depth = 0

    def handle_starttag(self, tag, attrs):
        if tag == 'template':
            self.template_depth += 1
        attrs = dict(attrs)
        if not self.template_depth and tag == 'meta' and (attrs.get('name') or '').lower() == 'viewport':
            self.viewports.append(attrs.get('content') or '')

    def handle_endtag(self, tag):
        if tag == 'template':
            self.template_depth = max(0, self.template_depth - 1)


def entry_input_warnings(app_dir, entry):
    """Static hints, not proof of working controls. Never changes an existing app."""
    try:
        # Use the same bounded, symlink-safe file reader as the files bridge.
        raw = read_file(app_dir, entry.split('/'), limit=MAX_PAGE)
    except (OSError, ValueError):
        return [f'{entry}: input layout was not checked; the entry could not be read within {MAX_PAGE} bytes']
    parser = _ViewportParser()
    parser.feed(raw.decode('utf-8', 'replace'))
    if not parser.viewports:
        return [f'{entry}: add <meta name="viewport" content="width=device-width, initial-scale=1"> for phone layout']
    warnings = []
    if len(parser.viewports) != 1:
        warnings.append(f'{entry}: use one viewport meta element; multiple declarations can conflict')
    for content in parser.viewports:
        settings = {}
        for part in re.split('[,;]', content.lower()):
            key, separator, value = part.partition('=')
            if separator:
                settings[key.strip()] = value.strip()
        try:
            initial_scale = float(settings.get('initial-scale', ''))
        except ValueError:
            initial_scale = None
        if settings.get('width') != 'device-width' or initial_scale != 1:
            warnings.append(f'{entry}: use viewport width=device-width, initial-scale=1 for phone layout')
        if settings.get('user-scalable') in ('no', '0') or 'maximum-scale' in settings:
            warnings.append(f'{entry}: avoid restricting viewport zoom; keep accessibility zoom available')
    return list(dict.fromkeys(warnings))


def publish(places, ident):
    """Validates the app and writes its desktop entry, so it appears in the Apps screen."""
    result = check(places, ident)
    if not result['ok']:
        return result
    manifest = result['manifest']
    if manifest['icon']:
        icon = os.path.realpath(os.path.join(places.app(ident), manifest['icon']))
    else:
        icon = os.path.join(places.app_data(ident), 'icon.svg')
        write_atomic(icon, default_icon(ident, manifest['name']).encode())
    write_atomic(places.entry(ident), desktop_entry(ident, manifest, icon).encode())
    return {**result, 'published': True, 'entry': places.entry(ident), 'icon': icon}


def list_apps(places):
    apps = []
    if not os.path.isdir(places.apps):
        return apps
    for name in sorted(os.listdir(places.apps)):
        if not ID.fullmatch(name) or not os.path.isdir(os.path.join(places.apps, name)):
            continue
        result = check(places, name)
        manifest = result.pop('manifest', None)
        apps.append({
            **result,
            'name': manifest['name'] if manifest else name,
            'description': manifest['description'] if manifest else '',
            'capabilities': manifest['capabilities'] if manifest else [],
            'dir': places.app(name),
            'published': os.path.isfile(places.entry(name)),
        })
    return apps


def remove(places, ident, purge=False):
    """Takes the app off the Apps screen; with purge, deletes its files and data too."""
    removed = []
    try:
        os.unlink(places.entry(ident))
        removed.append(places.entry(ident))
    except FileNotFoundError:
        pass
    if purge:
        for path in (places.app(ident), places.app_data(ident), places.web_cache(ident)):
            if os.path.islink(path):
                os.unlink(path)
                removed.append(path)
            elif os.path.isdir(path):
                shutil.rmtree(path)
                removed.append(path)
    return {'id': ident, 'removed': removed}


# Bridge requests.

def check_argv(argv):
    if not isinstance(argv, list) or not argv or len(argv) > MAX_ARGS:
        raise AppError(f'argv must be a list of 1 to {MAX_ARGS} strings')
    total = 0
    for arg in argv:
        if not isinstance(arg, str) or '\0' in arg or len(arg) > MAX_ARG:
            raise AppError(f'Each argument must be a string of at most {MAX_ARG} characters without NUL')
        total += len(arg)
    if not argv[0]:
        raise AppError('argv[0] must name a program')
    if total > MAX_ARGV:
        raise AppError(f'argv must be at most {MAX_ARGV} characters in all')
    return list(argv)


def check_env(env):
    if env is None:
        return {}
    if not isinstance(env, dict) or len(env) > MAX_ENV:
        raise AppError(f'env must be an object of at most {MAX_ENV} variables')
    for name, value in env.items():
        if not ENV_NAME.fullmatch(name):
            raise AppError(f'env name "{name[:40]}" is not a variable name')
        if not isinstance(value, str) or '\0' in value or len(value) > MAX_ENV_VALUE:
            raise AppError(f'env {name} must be a string of at most {MAX_ENV_VALUE} characters')
    return dict(env)


def check_timeout(value):
    if value is None:
        return DEFAULT_TIMEOUT_MS
    if not isinstance(value, int) or isinstance(value, bool) or not 1 <= value <= MAX_TIMEOUT_MS:
        raise AppError(f'timeoutMs must be an integer from 1 to {MAX_TIMEOUT_MS}')
    return value


def capped(chunks, limit=MAX_OUTPUT):
    """Joins output chunks, keeping at most limit bytes. Returns (bytes, truncated)."""
    data = b''.join(chunks)
    return (data[:limit], True) if len(data) > limit else (data, False)


def feed(pipe, data, deadline, close=True):
    """Writes data to a program's input pipe without ever blocking past deadline (a
    time.monotonic() value), so a program that does not read cannot hold its caller.
    Returns 'written', 'closed' (the program stopped reading its input) or 'timeout'.
    With close, the pipe is closed whatever the outcome."""
    fd = pipe.fileno()
    os.set_blocking(fd, False)
    view = memoryview(data)
    sent = 0
    try:
        while sent < len(view):
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return 'timeout'
            if not select.select([], [fd], [], remaining)[1]:
                continue
            try:
                sent += os.write(fd, view[sent:sent + 65536])
            except BlockingIOError:
                continue
            except (BrokenPipeError, ConnectionResetError):
                return 'closed'
        return 'written'
    finally:
        if close:
            try:
                pipe.close()
            except OSError:
                pass
        else:
            os.set_blocking(fd, True)


# The bridge's file operations. A path is absolute under the home, or relative to the
# app's files directory. Every directory on the way is opened with O_NOFOLLOW below a
# directory descriptor, and the last part is acted on through that descriptor, so a symlink
# swapped in between check and use cannot redirect a read, write or removal.

_DIR_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | getattr(os, 'O_CLOEXEC', 0)


def split_path(path, home, files):
    """(root, parts) for a bridge path; parts is empty for the root itself."""
    if not isinstance(path, str) or '\0' in path or len(path) > 4096:
        raise AppError('path must be a string of at most 4096 characters')
    if path.startswith('~/') or path == '~':
        path = home + path[1:]
    if path.startswith('/'):
        if path != home and not path.startswith(home + '/'):
            raise AppError(f'path must be inside {home}')
        root, rest = home, path[len(home):]
    else:
        root, rest = files, path
    parts = [p for p in rest.split('/') if p not in ('', '.')]
    if '..' in parts:
        raise AppError('path must not contain ".."')
    return root, parts


def open_cwd(path, home, files):
    """Open a working directory beneath home without traversing symlinks."""
    if path is None:
        path = '.'
    root, components = split_path(path, home, files)
    if root == files:
        relative = os.path.relpath(files, home)
        if relative == '..' or relative.startswith('../') or os.path.isabs(relative):
            raise AppError('The app data directory is outside the home')
        components = ([] if relative == '.' else relative.split('/')) + components
    return _open_dir(home, components)


def _open_dir(root, parts, create=False):
    """A descriptor of root/parts[...], refusing symlinks at every step."""
    if create:
        os.makedirs(root, mode=0o700, exist_ok=True)
    fd = os.open(root, _DIR_FLAGS)
    try:
        for part in parts:
            try:
                child = os.open(part, _DIR_FLAGS, dir_fd=fd)
            except FileNotFoundError:
                if not create:
                    raise
                try:
                    os.mkdir(part, 0o755, dir_fd=fd)
                except FileExistsError:
                    pass
                child = os.open(part, _DIR_FLAGS, dir_fd=fd)
            except OSError as error:
                if error.errno in (errno.ELOOP, errno.ENOTDIR, errno.EMLINK):
                    raise AppError(f'"{part}" is not a directory (symbolic links are not followed)') from None
                raise
            os.close(fd)
            fd = child
        return fd
    except BaseException:
        os.close(fd)
        raise


def _leaf(path_parts):
    if not path_parts:
        raise AppError('path must name a file, not the root')
    return path_parts[:-1], path_parts[-1]


def read_file(root, parts, limit=MAX_FILE):
    dirs, name = _leaf(parts)
    dfd = _open_dir(root, dirs)
    try:
        try:
            fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | getattr(os, 'O_CLOEXEC', 0), dir_fd=dfd)
        except OSError as error:
            if error.errno in (errno.ELOOP, errno.EMLINK):
                raise AppError(f'"{name}" is a symbolic link; it is not followed') from None
            raise
        with os.fdopen(fd, 'rb') as handle:
            if not stat.S_ISREG(os.fstat(handle.fileno()).st_mode):
                raise AppError(f'"{name}" is not a regular file')
            data = handle.read(limit + 1)
        if len(data) > limit:
            raise AppError(f'"{name}" is larger than {limit} bytes')
        return data
    finally:
        os.close(dfd)


def write_file(root, parts, data, create_dirs=True):
    """Writes through a new file in the same directory renamed over the target, so the write
    replaces a symlink rather than following it and readers never see a partial file."""
    if len(data) > MAX_FILE:
        raise AppError(f'A file write is at most {MAX_FILE} bytes')
    dirs, name = _leaf(parts)
    dfd = _open_dir(root, dirs, create=create_dirs)
    try:
        temp = f'.{name[:200]}.{secrets.token_hex(6)}.tmp'
        fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | getattr(os, 'O_CLOEXEC', 0), 0o644, dir_fd=dfd)
        try:
            with os.fdopen(fd, 'wb') as handle:
                handle.write(data)
                handle.flush()
                os.fsync(handle.fileno())
            try:
                if stat.S_ISDIR(os.stat(name, dir_fd=dfd, follow_symlinks=False).st_mode):
                    raise AppError(f'"{name}" is a directory')
            except FileNotFoundError:
                pass
            os.rename(temp, name, src_dir_fd=dfd, dst_dir_fd=dfd)
        except BaseException:
            try:
                os.unlink(temp, dir_fd=dfd)
            except FileNotFoundError:
                pass
            raise
    finally:
        os.close(dfd)
    return len(data)


def _describe(name, info):
    kind = 'directory' if stat.S_ISDIR(info.st_mode) else 'file' if stat.S_ISREG(info.st_mode) else \
        'symlink' if stat.S_ISLNK(info.st_mode) else 'other'
    return {'name': name, 'kind': kind, 'size': info.st_size, 'modified': int(info.st_mtime * 1000)}


def stat_path(root, parts):
    if not parts:
        return _describe('', os.stat(root, follow_symlinks=False))
    dirs, name = _leaf(parts)
    dfd = _open_dir(root, dirs)
    try:
        return _describe(name, os.stat(name, dir_fd=dfd, follow_symlinks=False))
    finally:
        os.close(dfd)


def list_dir(root, parts):
    fd = _open_dir(root, parts)
    try:
        listing = []
        with os.scandir(fd) as entries:
            for entry in entries:
                if len(listing) == MAX_LIST:
                    break
                listing.append(_describe(entry.name, entry.stat(follow_symlinks=False)))
        return sorted(listing, key=lambda item: item['name'])
    finally:
        os.close(fd)


def make_dir(root, parts):
    os.close(_open_dir(root, parts, create=True))


def remove_path(root, parts, recursive=False):
    dirs, name = _leaf(parts)
    dfd = _open_dir(root, dirs)
    try:
        info = os.stat(name, dir_fd=dfd, follow_symlinks=False)
        if stat.S_ISDIR(info.st_mode):
            if recursive:
                # rmtree with dir_fd walks by descriptor and never follows a symlink out.
                shutil.rmtree(name, dir_fd=dfd)
            else:
                os.rmdir(name, dir_fd=dfd)
        else:
            os.unlink(name, dir_fd=dfd)
    finally:
        os.close(dfd)
