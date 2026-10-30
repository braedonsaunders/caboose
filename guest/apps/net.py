"""Agent app network: the open network for an app that declares `net`.

A page's own requests are bound by the web's rules: cross-origin reads need the server's
CORS consent, and a secure page may not load plain http. An app that declares `net` reaches
any http or https URL through its network origin, a loopback HTTP server that only that app
instance knows (`http://127.0.0.1:<port>/<token>/`). A request to

    <base><scheme>/<authority><path>?<query>

is made to `<scheme>://<authority><path>?<query>` with the page's method, headers and body,
and the response streams back with its status and headers and CORS headers that admit the
app's page. The network origin is not the app's origin, so nothing fetched through it is
ever the app's own script: the app's content policy still runs script only from its files.

The device that runs an app natively serves the same contract itself (CabooseKit's
AgentAppNet). curl makes the requests here, so HTTP/2, plain-http SHOUTcast and Icecast
servers, redirects and compressed bodies all work. Standard library only.
"""
import hmac
import os
import re
import secrets
import shutil
import subprocess
import tempfile
import threading
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MAX_BODY = 64 * 1024 * 1024
MAX_URL = 16 * 1024
MAX_ACTIVE = 64
MAX_REDIRECTS = 10
CONNECT_TIMEOUT_S = 30
CHUNK = 64 * 1024
# A page names one of these through `X-Caboose-Header-<name>`, since browsers do not let
# script set them; caboose.fetch does the renaming.
OVERRIDE = 'x-caboose-header-'
# Request fields that describe the page's connection to the network origin, not the
# request: never sent upstream.
DROP_REQUEST = {'host', 'origin', 'referer', 'cookie', 'cookie2', 'connection', 'keep-alive', 'te', 'trailer',
                'transfer-encoding', 'upgrade', 'content-length', 'accept-encoding', 'expect', 'dnt',
                'proxy-authorization', 'proxy-connection', 'priority'}
DROP_REQUEST_PREFIXES = ('sec-', 'access-control-request-', 'proxy-')
# Response fields that describe the upstream connection, or would apply the remote site's
# policy to the app: never sent to the page.
DROP_RESPONSE = {'connection', 'keep-alive', 'te', 'trailer', 'transfer-encoding', 'upgrade', 'proxy-authenticate',
                 'strict-transport-security', 'alt-svc', 'set-cookie',
                 'set-cookie2', 'public-key-pins', 'clear-site-data', 'content-security-policy',
                 'content-security-policy-report-only', 'cross-origin-opener-policy', 'cross-origin-embedder-policy',
                 'cross-origin-resource-policy', 'timing-allow-origin', 'vary', 'server-timing', 'nel', 'report-to'}
TOKEN = re.compile(r"[!#$%&'*+\-.^_`|~0-9A-Za-z]+")


class NetError(ValueError):
    """A request the network origin refuses, with its status."""

    def __init__(self, status, message):
        super().__init__(message)
        self.status = status


def target(path, token):
    """The upstream URL a request path names, or NetError. `path` is the request target as
    sent: percent-encoded, with its query."""
    if not path.startswith('/') or len(path) > MAX_URL:
        raise NetError(400, 'Malformed request')
    raw, _, query = path.partition('?')
    parts = raw.split('/', 4)
    if len(parts) < 4 or not hmac.compare_digest(parts[1].encode(), token.encode()):
        raise NetError(404, 'Not found')
    scheme, authority = parts[2].lower(), urllib.parse.unquote(parts[3])
    rest = '/' + parts[4] if len(parts) == 5 else '/'
    if scheme not in ('http', 'https'):
        raise NetError(400, 'The network origin reaches http and https URLs')
    if not authority or any(c in authority for c in '@/\\?#') or any(ord(c) <= 32 or ord(c) >= 127 for c in authority):
        raise NetError(400, 'The URL has no valid host')
    if any(ord(c) <= 32 or ord(c) == 127 for c in rest + query):
        raise NetError(400, 'Malformed request')
    url = f'{scheme}://{authority}{rest}' + (f'?{query}' if query else '')
    try:
        parsed = urllib.parse.urlsplit(url)
        parsed.port  # noqa: B018 - raises on a malformed port
    except ValueError:
        raise NetError(400, 'The URL has no valid host') from None
    if not parsed.hostname:
        raise NetError(400, 'The URL has no valid host')
    return url


def upstream_headers(fields):
    """The headers sent upstream, from the request's (name, value) pairs in order."""
    sent, overrides = [], []
    for name, value in fields:
        lower = name.lower()
        if '\r' in value or '\n' in value or '\0' in value or not TOKEN.fullmatch(name):
            continue
        if lower.startswith(OVERRIDE):
            real = name[len(OVERRIDE):]
            if TOKEN.fullmatch(real or '-') and real.lower() not in ('host', 'content-length', 'transfer-encoding', 'connection'):
                overrides.append((real, value))
            continue
        if lower in DROP_REQUEST or lower.startswith(DROP_REQUEST_PREFIXES):
            continue
        sent.append((name, value))
    replaced = {name.lower() for name, _ in overrides}
    return [(n, v) for n, v in sent if n.lower() not in replaced] + overrides


def allowed_origin(origin, app_origin):
    """The Access-Control-Allow-Origin for a request's Origin, or None to refuse it. A
    request without one (a media element, an image) is the token's to admit."""
    if origin is None:
        return '*'
    if origin == app_origin or origin == 'null':
        return origin
    return None


def response_headers(fields, origin, final_url):
    """The headers sent to the page, from upstream's (name, value) pairs. A compressed body
    arrives decoded, so its encoding and length no longer apply."""
    decoded = any(name.lower() == 'content-encoding' for name, _ in fields)
    sent = []
    for name, value in fields:
        lower = name.lower()
        if lower.startswith('access-control-') or lower in DROP_RESPONSE or \
                (decoded and lower in ('content-encoding', 'content-length')):
            if lower in ('set-cookie', 'set-cookie2'):
                sent.append(('X-Caboose-Set-Cookie', value))
            continue
        sent.append((name, value))
    sent += [('Access-Control-Allow-Origin', origin), ('Access-Control-Expose-Headers', '*'),
             ('Vary', 'Origin'), ('X-Caboose-Url', final_url)]
    return sent


def preflight(fields, origin):
    method = fields.get('access-control-request-method', 'GET')
    headers = fields.get('access-control-request-headers', '*')
    return [('Access-Control-Allow-Origin', origin), ('Access-Control-Allow-Methods', method),
            ('Access-Control-Allow-Headers', headers or '*'), ('Access-Control-Max-Age', '600'),
            ('Vary', 'Origin'), ('Content-Length', '0')]


STATUS_LINE = re.compile(r'(?:HTTP/[\d.]+|ICY)\s+(\d{3})(?:\s+(.*))?$', re.IGNORECASE)


def read_head(stream, following=True):
    """Reads curl's dumped header blocks until the final response's: (status, reason,
    [(name, value)], final_url). Interim (1xx) responses and followed redirects are skipped."""
    location = None
    url = None
    while True:
        lines = []
        while True:
            line = stream.readline(MAX_URL)
            if not line:
                return None
            line = line.decode('latin-1').rstrip('\r\n')
            if not line:
                if lines:
                    break
                continue
            lines.append(line)
        match = STATUS_LINE.match(lines[0])
        if not match:
            return None
        status = int(match.group(1))
        fields = []
        for line in lines[1:]:
            name, sep, value = line.partition(':')
            if sep and TOKEN.fullmatch(name.strip()):
                fields.append((name.strip(), value.strip()))
        location = next((v for n, v in fields if n.lower() == 'location'), None)
        if 100 <= status < 200:
            continue
        if following and 300 <= status < 400 and location:
            url = location if url is None else urllib.parse.urljoin(url, location)
            continue
        return status, (match.group(2) or '').strip(), fields, url


def curl_config(url, method, headers, has_body):
    """curl's options, as a config file, so the URL and credentials stay out of argv."""
    def quote(value):
        return '"' + value.replace('\\', '\\\\').replace('"', '\\"') + '"'
    lines = [f'url = {quote(url)}', 'silent', 'show-error', 'location', f'max-redirs = {MAX_REDIRECTS}',
             'compressed', 'no-buffer', f'connect-timeout = {CONNECT_TIMEOUT_S}', 'dump-header = "-"',
             'output = "-"', 'proto-default = https', 'proto = "=http,https"', 'proto-redir = "=http,https"']
    if method == 'HEAD':
        lines.append('head')
    elif method == 'POST' and has_body:
        pass  # --data-binary makes it a POST, which redirects follow as a browser does
    elif method != 'GET' or has_body:
        lines.append(f'request = {quote(method)}')
    if has_body:
        lines.append('data-binary = "@-"')
        # Without the page's own type, curl would call the body a form.
        if not any(name.lower() == 'content-type' for name, _ in headers):
            lines.append('header = "Content-Type:"')
    for name, value in headers:
        lines.append(f'header = {quote(f"{name}: {value}")}')
    # Without a User-Agent of the page's, curl's own is sent.
    if not any(name.lower() == 'user-agent' for name, _ in headers):
        lines.append('user-agent = "Mozilla/5.0 (X11; Linux) Caboose"')
    return '\n'.join(lines) + '\n'


class NetOrigin:
    """The network origin of one app instance."""

    def __init__(self, app_origin, curl=None):
        self.app_origin = app_origin
        self.curl = curl or shutil.which('curl') or 'curl'
        self.token = secrets.token_hex(16)
        self.active = threading.BoundedSemaphore(MAX_ACTIVE)
        self.processes = set()
        self.lock = threading.Lock()
        self.directory = tempfile.mkdtemp(prefix='caboose-net-')
        origin = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = 'HTTP/1.1'
            server_version = 'Caboose'
            sys_version = ''

            def log_message(self, *_):
                pass

            def handle_one_request(self):
                try:
                    self.raw_requestline = self.rfile.readline(MAX_URL + 1)
                    if not self.raw_requestline or len(self.raw_requestline) > MAX_URL:
                        self.close_connection = True
                        return
                    if not self.parse_request():
                        return
                    origin.handle(self)
                except (BrokenPipeError, ConnectionResetError, TimeoutError):
                    pass
                self.close_connection = True

        self.server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self.server.daemon_threads = True
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    @property
    def base(self):
        return f'http://127.0.0.1:{self.server.server_address[1]}/{self.token}/'

    def close(self):
        self.server.shutdown()
        self.server.server_close()
        with self.lock:
            running = list(self.processes)
        for proc in running:
            if proc.poll() is None:
                proc.kill()
        shutil.rmtree(self.directory, ignore_errors=True)

    @staticmethod
    def _answer(handler, status, message, headers=()):
        body = (message + '\n').encode()
        handler.send_response(status)
        for name, value in headers:
            handler.send_header(name, value)
        handler.send_header('Content-Type', 'text/plain; charset=utf-8')
        handler.send_header('Content-Length', str(len(body)))
        handler.send_header('X-Caboose-Error', message[:300])
        handler.send_header('Connection', 'close')
        handler.end_headers()
        if handler.command != 'HEAD':
            handler.wfile.write(body)

    def handle(self, handler):
        fields = {name.lower(): value for name, value in handler.headers.items()}
        cors = allowed_origin(handler.headers.get('Origin'), self.app_origin)
        if cors is None:
            return self._answer(handler, 403, 'Only the app may use its network origin')
        cors_headers = [('Access-Control-Allow-Origin', cors), ('Access-Control-Expose-Headers', '*'), ('Vary', 'Origin')]
        try:
            url = target(handler.path, self.token)
        except NetError as error:
            return self._answer(handler, error.status, str(error), cors_headers)
        if handler.command == 'OPTIONS' and 'access-control-request-method' in fields:
            handler.send_response(204)
            for name, value in preflight(fields, cors):
                handler.send_header(name, value)
            handler.send_header('Connection', 'close')
            return handler.end_headers()
        if 'chunked' in fields.get('transfer-encoding', '').lower():
            return self._answer(handler, 411, 'Send a request body with a length', cors_headers)
        try:
            length = int(fields.get('content-length') or 0)
        except ValueError:
            length = -1
        if not 0 <= length <= MAX_BODY:
            return self._answer(handler, 413, f'A request body is at most {MAX_BODY} bytes', cors_headers)
        if not self.active.acquire(blocking=False):
            return self._answer(handler, 503, f'At most {MAX_ACTIVE} requests are open at once', cors_headers)
        try:
            self._forward(handler, url, length, cors, cors_headers)
        finally:
            self.active.release()

    def _forward(self, handler, url, length, cors, cors_headers):
        method = handler.command
        config = curl_config(url, method, upstream_headers(handler.headers.items()), length > 0)
        fd, path = tempfile.mkstemp(dir=self.directory)
        with os.fdopen(fd, 'w') as handle:
            handle.write(config)
        try:
            proc = subprocess.Popen([self.curl, '--config', path], stdin=subprocess.PIPE if length else subprocess.DEVNULL,
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
        except OSError as error:
            os.unlink(path)
            return self._answer(handler, 502, f'curl could not start: {error.strerror or error}', cors_headers)
        with self.lock:
            self.processes.add(proc)
        try:
            if length:
                feeder = threading.Thread(target=self._feed, args=(handler.rfile, proc.stdin, length), daemon=True)
                feeder.start()
            head = read_head(proc.stdout)
            os.unlink(path)
            path = None
            if head is None:
                proc.kill()
                proc.wait()
                lines = proc.stderr.read(4096).decode('utf-8', 'replace').strip().splitlines()
                reason = lines[-1] if lines else 'The server did not answer'
                reason = re.sub(r'^curl: \(\d+\)\s*', '', reason)
                return self._answer(handler, 502, reason, cors_headers)
            status, reason, fields, moved = head
            handler.send_response(status, reason or None)
            for name, value in response_headers(fields, cors, moved or url):
                handler.send_header(name, value)
            handler.send_header('Connection', 'close')
            handler.end_headers()
            if method == 'HEAD':
                return
            while True:
                chunk = proc.stdout.read1(CHUNK)
                if not chunk:
                    break
                handler.wfile.write(chunk)
        finally:
            if path:
                os.unlink(path)
            if proc.poll() is None:
                proc.kill()
            proc.wait()
            for stream in (proc.stdout, proc.stderr):
                stream.close()
            with self.lock:
                self.processes.discard(proc)

    @staticmethod
    def _feed(source, sink, length):
        try:
            while length > 0:
                chunk = source.read(min(CHUNK, length))
                if not chunk:
                    break
                sink.write(chunk)
                length -= len(chunk)
        except (OSError, ValueError):
            pass
        finally:
            try:
                sink.close()
            except OSError:
                pass
