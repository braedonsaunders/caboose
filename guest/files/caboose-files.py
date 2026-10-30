#!/usr/bin/env python3
"""Private, token-authenticated filesystem service. All path operations use dirfds."""
import ctypes
import event_stream
import errno
import hashlib
import hmac
import json
import mimetypes
import os
import re
import select
import struct
import subprocess
import secrets
import socket
import stat
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, quote, urlsplit

ROOT = os.environ.get('CABOOSE_FILES_ROOT', '/home/caboose')
TOKEN = os.environ.get('CABOOSE_FILES_TOKEN_FILE', '/run/caboose/display-token')
PORT = int(os.environ.get('CABOOSE_FILES_PORT', '14700'))
DIR = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
rootfd = os.open(ROOT, DIR)
lock = threading.RLock()
keyring_lock = threading.Lock()
bridge_slots = threading.BoundedSemaphore(20)
event_slots = threading.BoundedSemaphore(2)
BRIDGE_MAX = 96 * 1024 * 1024
BRIDGE_RUNTIME = os.environ.get('CABOOSE_BRIDGE_RUNTIME', f'/run/user/{os.getuid()}')


def bridge_receive(sock, count):
    chunks = bytearray()
    while len(chunks) < count:
        part = sock.recv(min(65536, count - len(chunks)))
        if not part:
            raise ConnectionError('app bridge closed')
        chunks.extend(part)
    return bytes(chunks)


def bridge_open(instance):
    if not re.fullmatch(r'[0-9a-f]{32}', instance):
        raise ValueError('invalid app bridge instance')
    path = os.path.join(BRIDGE_RUNTIME, f'caboose-app-{instance}.sock')
    connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        connection.settimeout(660)
        connection.connect(path)
        return connection
    except BaseException:
        connection.close()
        raise


def parts(path):
    if not isinstance(path, str) or '\0' in path or path.startswith('/'):
        raise ValueError('invalid path')
    p = path.split('/') if path else []
    if any(x in ('', '.', '..') or x.startswith('.caboose-upload-') for x in p):
        raise ValueError('invalid path')
    return p


def directory(components):
    fd = os.dup(rootfd)
    try:
        for name in components:
            new = os.open(name, DIR, dir_fd=fd)
            os.close(fd)
            fd = new
        return fd
    except BaseException:
        os.close(fd)
        raise


def parent(path):
    components = parts(path)
    if not components:
        raise ValueError('root cannot be modified')
    return directory(components[:-1]), components[-1]


def rename_no_replace(srcfd, src, dstfd, dst):
    libc = ctypes.CDLL(None, use_errno=True)
    rename = libc.renameat2
    rename.argtypes = (ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint)
    if rename(srcfd, os.fsencode(src), dstfd, os.fsencode(dst), 1) != 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error))


def version(s):
    # Nanoseconds and inode distinguish replacement as well as in-place modification.
    return '"' + hashlib.sha256(f'{s.st_dev}:{s.st_ino}:{s.st_size}:{s.st_mtime_ns}:{s.st_ctime_ns}'.encode()).hexdigest() + '"'


def item(name, s):
    if stat.S_ISLNK(s.st_mode) or not (stat.S_ISREG(s.st_mode) or stat.S_ISDIR(s.st_mode)):
        raise ValueError('unsupported file type')
    return {'identity': f'{s.st_dev}:{s.st_ino}', 'name': name, 'kind': 'directory' if stat.S_ISDIR(s.st_mode) else 'file', 'size': s.st_size,
            'mtime': s.st_mtime_ns // 1_000_000, 'etag': version(s),
            'contentType': 'inode/directory' if stat.S_ISDIR(s.st_mode) else (mimetypes.guess_type(name)[0] or 'application/octet-stream')}


def file_stat(path):
    if not path:
        return item('', os.fstat(rootfd))
    fd, name = parent(path)
    try:
        return item(name, os.stat(name, dir_fd=fd, follow_symlinks=False))
    finally:
        os.close(fd)


def byte_range(header, size):
    if header is None:
        return (0, size - 1, False)
    m = re.fullmatch(r'bytes=(\d*)-(\d*)', header)
    if not m or not (m[1] or m[2]) or not size:
        raise ValueError('invalid range')
    if not m[1]:
        n = int(m[2])
        if n <= 0:
            raise ValueError('invalid range')
        return (max(0, size - n), size - 1, True)
    start = int(m[1]); end = min(int(m[2]), size - 1) if m[2] else size - 1
    if start >= size or end < start:
        raise ValueError('invalid range')
    return (start, end, True)


class Changes:
    """Bounded inotify journal; a stale or overflowed anchor requires a rescan."""
    def __init__(self):
        self.epoch = secrets.token_hex(16)
        self.sequence = 0
        self.guard = threading.Lock()
        self.events = []
        self.wake_read, self.wake_write = os.pipe2(os.O_NONBLOCK | os.O_CLOEXEC)
        self.healthy = True
        libc = ctypes.CDLL(None, use_errno=True)
        self.add = libc.inotify_add_watch
        self.add.argtypes = (ctypes.c_int, ctypes.c_char_p, ctypes.c_uint32)
        self.remove = libc.inotify_rm_watch
        self.remove.argtypes = (ctypes.c_int, ctypes.c_int)
        self.fd = libc.inotify_init1(os.O_NONBLOCK | os.O_CLOEXEC)
        if self.fd < 0: raise OSError(ctypes.get_errno(), 'inotify_init1')
        self.watches = {}
        self.scan()
        threading.Thread(target=self.run, daemon=True).start()
    def scan(self):
        found = {}
        pending = ['']
        while pending:
            relative = pending.pop()
            try: fd = directory(parts(relative))
            except (FileNotFoundError, NotADirectoryError, PermissionError): continue
            try:
                wd = self.add(self.fd, os.fsencode(f'/proc/self/fd/{fd}'), 0x00000FCE | 0x01000000)
                if wd < 0: raise OSError(ctypes.get_errno(), 'inotify_add_watch')
                found[wd] = os.path.join(ROOT, relative)
                for name in os.listdir(fd):
                    if name.startswith('.caboose-upload-'): continue
                    try: mode = os.stat(name, dir_fd=fd, follow_symlinks=False).st_mode
                    except FileNotFoundError: continue
                    if stat.S_ISDIR(mode): pending.append(f'{relative}/{name}' if relative else name)
            finally: os.close(fd)
        for wd in self.watches.keys() - found.keys(): self.remove(self.fd, wd)
        self.watches = found
    def invalidate(self):
        self.epoch = secrets.token_hex(16); self.sequence = 0; self.events = []
    def run(self):
        while True:
            ready, _, _ = select.select([self.fd], [], [], None if self.healthy else 2)
            if not ready:
                if not self.healthy:
                    try:
                        self.scan()
                        with self.guard: self.healthy = True
                    except OSError: pass
                continue
            data = os.read(self.fd, 1024 * 1024)
            offset = 0; changed = []; invalid = False; rescan = False
            while offset < len(data):
                wd, mask, cookie, length = struct.unpack_from('iIII', data, offset)
                raw = data[offset + 16:offset + 16 + length].split(b'\0', 1)[0]
                offset += 16 + length
                if mask & 0x00008000: continue  # IN_IGNORED after removing an old watch
                base = self.watches.get(wd)
                if mask & 0x4000 or base is None: invalid = True; continue
                if os.fsdecode(raw).startswith('.caboose-upload-'): continue
                path = os.path.relpath(os.path.join(base, os.fsdecode(raw)), ROOT)
                if path == '.': path = ''
                if path == '.cache/caboose/bridge/present': continue
                if mask & 0x40000000: rescan = True
                if mask & (0x00000400 | 0x00000800): invalid = True
                changed.append({'path': path, 'removed': bool(mask & (0x00000040 | 0x00000200)), 'cookie': cookie})
            with self.guard:
                if invalid: self.invalidate()
                if changed:
                    self.sequence += 1
                    self.events.append((self.sequence, changed))
                    self.events = self.events[-10000:]
            if changed or invalid:
                try: os.write(self.wake_write, b'x')
                except BlockingIOError: pass
            if rescan or invalid:
                try:
                    self.scan()
                    with self.guard:
                        self.healthy = True
                        self.invalidate()
                    try: os.write(self.wake_write, b'x')
                    except BlockingIOError: pass
                except OSError:
                    with self.guard:
                        self.invalidate()
                        self.healthy = False
    def anchor(self):
        with self.guard: return f'{self.epoch}:{self.sequence}'
    def changes(self, old):
        with self.guard:
            if not self.healthy: raise OSError('inotify watch unavailable')
            anchor = f'{self.epoch}:{self.sequence}'
            try:
                epoch, number = old.rsplit(':', 1); number = int(number)
                valid = epoch == self.epoch and 0 <= number <= self.sequence
                valid = valid and (not self.events or number >= self.events[0][0] - 1)
            except (ValueError, AttributeError): valid = False; number = -1
            events = [item for seq, batch in self.events if seq > number for item in batch] if valid else []
            return {'anchor': anchor, 'changed': old != anchor, 'reset': not valid, 'events': events}


changes = None
events = event_stream.Events(directory)


def trash(path):
    source, name = parent(path)
    try:
        item(name, os.stat(name, dir_fd=source, follow_symlinks=False))
        for p in ('.local', '.local/share', '.local/share/Trash', '.local/share/Trash/files', '.local/share/Trash/info'):
            ps = parts(p); fd = directory(ps[:-1])
            try:
                try: os.mkdir(ps[-1], 0o700, dir_fd=fd)
                except FileExistsError: pass
            finally: os.close(fd)
        files = directory(parts('.local/share/Trash/files'))
        info = directory(parts('.local/share/Trash/info'))
        try:
            unique = name + '.' + secrets.token_hex(12)
            infofd = os.open(unique + '.trashinfo', os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=info)
            try:
                body = '[Trash Info]\nPath=' + quote(os.path.join(ROOT, path), safe='/') + '\nDeletionDate=' + time.strftime('%Y-%m-%dT%H:%M:%S') + '\n'
                os.write(infofd, body.encode()); os.fsync(infofd)
            finally: os.close(infofd)
            try: rename_no_replace(source, name, files, unique)
            except BaseException:
                os.unlink(unique + '.trashinfo', dir_fd=info); raise
        finally: os.close(files); os.close(info)
    finally: os.close(source)


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, fmt, *args):
        pass
    def reply(self, status, body=None, headers=None):
        data = json.dumps(body, separators=(',', ':')).encode() if body is not None else b''
        self.send_response(status)
        # Error paths may reject a request before reading its body. Never reuse that
        # connection with unread bytes, which could otherwise become a new request.
        if status >= 400:
            self.close_connection = True
            self.send_header('Connection', 'close')
        self.send_header('Content-Length', str(len(data)))
        if body is not None: self.send_header('Content-Type', 'application/json')
        for k, v in (headers or {}).items(): self.send_header(k, str(v))
        self.end_headers()
        if data: self.wfile.write(data)
    def body(self, limit=65536):
        n = int(self.headers.get('Content-Length', '0'))
        if n < 0 or n > limit: raise ValueError('body too large')
        return json.loads(self.rfile.read(n))
    def handle_request(self):
        try:
            with open(TOKEN, 'rb') as f: token = f.read().decode()
            if not hmac.compare_digest(self.headers.get('Authorization', ''), 'Bearer ' + token):
                self.close_connection = True
                return self.reply(401, {'error': 'unauthorized'})
            u = urlsplit(self.path); q = parse_qs(u.query, keep_blank_values=True)
            if self.command == 'GET' and u.path == '/event-capabilities':
                return self.reply(200, {'version': 2})
            if self.command == 'POST' and u.path == '/events/presence':
                return self.reply(200 if events.lease(self.body()) else 409, {'ok': True})
            if self.command == 'POST' and u.path == '/events':
                if self.headers.get('Transfer-Encoding') or not self.headers.get('Content-Length'):
                    raise ValueError('event body length required')
                self.connection.settimeout(25)
                def authorized():
                    with open(TOKEN, 'rb') as current:
                        return hmac.compare_digest(token, current.read().decode())
                if not event_slots.acquire(blocking=False):
                    return self.reply(429, {'error': 'event capacity'})
                try: return events.serve(self, self.body(256 * 1024), changes, authorized)
                finally: event_slots.release()

            bridge = re.fullmatch(r'/webview/([0-9a-f]{32})', u.path)
            if bridge:
                length = self.headers.get('Content-Length', '')
                if (self.command != 'POST' or self.headers.get('Transfer-Encoding') or
                        not re.fullmatch(r'0|[1-9][0-9]*', length) or int(length) > BRIDGE_MAX):
                    return self.reply(400, {'error': 'invalid bridge request'})
                if not bridge_slots.acquire(blocking=False):
                    return self.reply(503, {'error': 'app bridge busy'})
                sent_headers = False
                try:
                    self.connection.settimeout(30)
                    with bridge_open(bridge.group(1)) as connection:
                        remaining = int(length)
                        connection.sendall(struct.pack('<I', remaining))
                        while remaining:
                            chunk = self.rfile.read(min(65536, remaining))
                            if not chunk:
                                raise ConnectionError('incomplete bridge request')
                            connection.sendall(chunk)
                            remaining -= len(chunk)
                        size, = struct.unpack('<I', bridge_receive(connection, 4))
                        if size > BRIDGE_MAX:
                            raise ValueError('app bridge reply too large')
                        self.send_response(200)
                        self.send_header('Content-Type', 'application/json')
                        self.send_header('Cache-Control', 'no-store')
                        self.send_header('Content-Length', str(size))
                        self.end_headers()
                        sent_headers = True
                        while size:
                            chunk = connection.recv(min(65536, size))
                            if not chunk:
                                raise ConnectionError('incomplete bridge reply')
                            self.wfile.write(chunk)
                            size -= len(chunk)
                except (OSError, ValueError):
                    if sent_headers:
                        self.close_connection = True
                    else:
                        return self.reply(503, {'error': 'app bridge unavailable'})
                finally:
                    bridge_slots.release()
                return
            if u.path == '/keyring':
                headers = {'Cache-Control': 'no-store'}
                if self.command != 'POST' or self.headers.get('Transfer-Encoding') or self.headers.get('Content-Length') != '64':
                    return self.reply(400, {'state': 'unavailable'}, headers)
                self.connection.settimeout(10)
                password = self.rfile.read(64)
                if len(password) != 64 or any(c not in b'0123456789abcdef' for c in password):
                    return self.reply(400, {'state': 'unavailable'}, headers)
                if not keyring_lock.acquire(blocking=False):
                    return self.reply(409, {'state': 'unavailable'}, headers)
                try:
                    result = subprocess.run(['/usr/bin/python3', '/opt/caboose/keyring/caboose-keyring'],
                                            input=password, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=45)
                    state = 'ready' if result.returncode == 0 and result.stdout.strip() == b'{"state": "ready"}' else 'migration-required' if result.returncode == 3 else 'unavailable'
                    return self.reply(200 if state == 'ready' else 409, {'state': state}, headers)
                except Exception:
                    return self.reply(503, {'state': 'unavailable'}, headers)
                finally:
                    keyring_lock.release()
            path = q.get('path', [''])[0]
            parts(path)
            if self.command == 'GET' and u.path == '/changes':
                return self.reply(200, changes.changes(q.get('anchor', [''])[0]))
            if self.command == 'GET' and u.path == '/stat':
                return self.reply(200, file_stat(path))
            if self.command == 'GET' and u.path == '/list':
                fd = directory(parts(path))
                try:
                    entries = []
                    for name in os.listdir(fd):
                        if name.startswith('.caboose-upload-'): continue
                        try: entries.append(item(name, os.stat(name, dir_fd=fd, follow_symlinks=False)))
                        except (ValueError, FileNotFoundError): continue
                    return self.reply(200, {'items': entries})
                finally: os.close(fd)
            if self.command == 'GET' and u.path == '/content':
                fd, name = parent(path)
                try: file = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=fd)
                finally: os.close(fd)
                try:
                    s = os.fstat(file)
                    if not stat.S_ISREG(s.st_mode): raise ValueError('not a file')
                    match = self.headers.get('If-Match')
                    if match and match != '*' and match != version(s):
                        return self.reply(412, {'error': 'version mismatch'})
                    try: start, end, partial = byte_range(self.headers.get('Range'), s.st_size)
                    except ValueError: return self.reply(416, headers={'Content-Range': f'bytes */{s.st_size}'})
                    self.send_response(206 if partial else 200)
                    self.send_header('Content-Length', str(max(0, end - start + 1)))
                    self.send_header('Accept-Ranges', 'bytes'); self.send_header('ETag', version(s))
                    self.send_header('Content-Type', mimetypes.guess_type(name)[0] or 'application/octet-stream')
                    if partial: self.send_header('Content-Range', f'bytes {start}-{end}/{s.st_size}')
                    self.end_headers(); os.lseek(file, start, os.SEEK_SET)
                    left = max(0, end - start + 1)
                    while left:
                        chunk = os.read(file, min(left, 1024 * 1024))
                        if not chunk: break
                        self.wfile.write(chunk); left -= len(chunk)
                finally: os.close(file)
                return
            if self.command == 'PUT' and u.path == '/content':
                return self.upload(path)
            if self.command == 'DELETE' and u.path == '/item':
                with lock:
                    match = self.headers.get('If-Match')
                    if match and match not in ('*', file_stat(path)['etag']):
                        return self.reply(412, {'error': 'version mismatch'})
                    trash(path)
                return self.reply(200, {'deleted': True})
            if self.command == 'POST' and u.path == '/mkdir':
                fd, name = parent(path)
                try: os.mkdir(name, dir_fd=fd)
                finally: os.close(fd)
                return self.reply(201, file_stat(path))
            if self.command == 'POST' and u.path == '/move':
                target = self.body().get('destination'); srcfd, src = parent(path)
                try:
                    dstfd, dst = parent(target)
                    try:
                        with lock:
                            current = item(src, os.stat(src, dir_fd=srcfd, follow_symlinks=False))
                            match = self.headers.get('If-Match')
                            if match and match not in ('*', current['etag']):
                                return self.reply(412, {'error': 'version mismatch'})
                            rename_no_replace(srcfd, src, dstfd, dst)
                    finally: os.close(dstfd)
                finally: os.close(srcfd)
                return self.reply(200, file_stat(target))
            self.reply(404, {'error': 'not found'})
        except (ValueError, TypeError, json.JSONDecodeError): self.close_connection = True; self.reply(400, {'error': 'invalid request'})
        except FileNotFoundError: self.reply(404, {'error': 'not found'})
        except (PermissionError, NotADirectoryError): self.reply(403, {'error': 'access denied'})
        except FileExistsError: self.reply(409, {'error': 'already exists'})
        except BrokenPipeError: pass
        except OSError: self.close_connection = True; self.reply(500, {'error': 'filesystem error'})
    def upload(self, path):
        fd, name = parent(path); temp = '.caboose-upload-' + secrets.token_hex(16)
        try:
            length = self.headers.get('Content-Length')
            chunked = self.headers.get('Transfer-Encoding', '').lower() == 'chunked'
            if length is None and not chunked: return self.reply(411, {'error': 'content length required'})
            if length is not None and chunked: raise ValueError('ambiguous length')
            left = int(length) if length is not None else 0
            if left < 0: raise ValueError('invalid length')
            out = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=fd)
            try:
                while True:
                    if chunked:
                        line = self.rfile.readline(8193)
                        if len(line) > 8192 or not line.endswith(b'\r\n'): raise ValueError('invalid chunk')
                        left = int(line.split(b';', 1)[0], 16)
                        if left < 0: raise ValueError('invalid chunk')
                        if not left:
                            while True:
                                trailer = self.rfile.readline(8193)
                                if len(trailer) > 8192 or not trailer.endswith(b'\r\n'): raise ValueError('invalid trailer')
                                if trailer == b'\r\n': break
                            break
                    elif not left: break
                    while left:
                        chunk = self.rfile.read(min(left, 1024 * 1024))
                        if not chunk: raise ValueError('incomplete upload')
                        view = memoryview(chunk)
                        while view: view = view[os.write(out, view):]
                        left -= len(chunk)
                    if chunked and self.rfile.read(2) != b'\r\n': raise ValueError('invalid chunk')
                os.fsync(out)
            finally: os.close(out)
            with lock:
                try: current = os.stat(name, dir_fd=fd, follow_symlinks=False)
                except FileNotFoundError: current = None
                if current is not None:
                    item(name, current)
                    if not stat.S_ISREG(current.st_mode): return self.reply(409, {'error': 'not a file'})
                match = self.headers.get('If-Match')
                if current is not None and not match and self.headers.get('If-None-Match') != '*':
                    return self.reply(428, {'error': 'If-Match required'})
                if match and (current is None or (match != '*' and match != version(current))):
                    return self.reply(412, {'error': 'version mismatch'})
                if self.headers.get('If-None-Match') == '*' and current is not None:
                    return self.reply(412, {'error': 'already exists'})
                if current is None:
                    try: rename_no_replace(fd, temp, fd, name)
                    except FileExistsError: return self.reply(412, {'error': 'already exists'})
                else:
                    os.rename(temp, name, src_dir_fd=fd, dst_dir_fd=fd)
            return self.reply(200 if current else 201, file_stat(path))
        finally:
            try: os.unlink(temp, dir_fd=fd)
            except FileNotFoundError: pass
            os.close(fd)
    do_GET = handle_request
    do_PUT = handle_request
    do_POST = handle_request
    do_DELETE = handle_request

class Server(ThreadingHTTPServer):
    daemon_threads = True
    slots = threading.BoundedSemaphore(64)
    def process_request(self, connection, address):
        if not self.slots.acquire(blocking=False):
            self.shutdown_request(connection)
            return
        connection.settimeout(25)
        try: super().process_request(connection, address)
        except BaseException: self.slots.release(); raise
    def process_request_thread(self, connection, address):
        try: super().process_request_thread(connection, address)
        finally: self.slots.release()


if __name__ == '__main__':
    changes = Changes()
    Server(('0.0.0.0', PORT), Handler).serve_forever()
