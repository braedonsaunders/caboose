#!/usr/bin/env python3
"""The owner's terminals: login shells on pseudo-terminals, over a token-authenticated WebSocket.

Each connection is one session. Sessions outlive their connection, so a client that drops
(the phone went to the background, the computer parked) reattaches and continues from the
byte it last received. The protocol is in docs/architecture.md § Terminal.
"""
import asyncio
import errno
import fcntl
import hashlib
import hmac
import json
import os
import pwd
import re
import secrets
import shlex
import signal
import struct
import termios
import time
from http import HTTPStatus
from urllib.parse import parse_qs, urlsplit

TOKEN = os.environ.get('CABOOSE_TERMINAL_TOKEN_FILE', '/run/caboose/display-token')
PORT = int(os.environ.get('CABOOSE_TERMINAL_PORT', '14701'))
DISPLAY_ENV = os.environ.get('CABOOSE_TERMINAL_DISPLAY_ENV', '/run/caboose/display.env')
MAX_SESSIONS = 16
REPLAY_BYTES = 256 * 1024
MAX_COLS, MAX_ROWS = 1000, 500
READ_BYTES = 64 * 1024
# Output waiting for a slow client; above HIGH the shell's output is no longer read, so
# the shell blocks on its own writes, as it would on a slow serial line.
HIGH, LOW = 256 * 1024, 64 * 1024
SESSION_ID = re.compile(r'[0-9a-f]{32}')
# DEC private modes a reattaching client restores when the replay no longer holds the
# sequence that set them: cursor keys, cursor visibility, the alternate screen, mouse
# reporting, focus events and bracketed paste.
TRACKED_MODES = {1: False, 25: True, 47: False, 1000: False, 1002: False, 1003: False, 1004: False,
                 1006: False, 1047: False, 1049: False, 2004: False}
TITLE_LIMIT = 200
CLOSE_REPLACED, CLOSE_INVALID = 4001, 4400


class BadRequest(ValueError):
    pass


def size(query, name, limit):
    values = query.get(name)
    if not values or not re.fullmatch(r'[0-9]{1,4}', values[0]) or not 1 <= int(values[0]) <= limit:
        raise BadRequest(f'{name} must be an integer from 1 to {limit}')
    return int(values[0])


def parse_attach(target):
    """`/?cols=&rows=[&session=][&offset=]` → (cols, rows, session or None, offset or None)."""
    query = parse_qs(urlsplit(target).query, keep_blank_values=True)
    cols, rows = size(query, 'cols', MAX_COLS), size(query, 'rows', MAX_ROWS)
    session = query.get('session', [None])[0]
    if session is not None and not SESSION_ID.fullmatch(session):
        raise BadRequest('invalid session')
    offset = query.get('offset', [None])[0]
    if offset is not None:
        if session is None or not re.fullmatch(r'[0-9]{1,15}', offset):
            raise BadRequest('invalid offset')
        offset = int(offset)
    return cols, rows, session, offset


def parse_control(text):
    """A client's control message: `{type: "resize", cols, rows}` or `{type: "hangup"}`."""
    try:
        message = json.loads(text)
    except ValueError:
        raise BadRequest('control messages are JSON')
    if not isinstance(message, dict):
        raise BadRequest('control messages are JSON objects')
    kind = message.get('type')
    if kind == 'resize':
        cols, rows = message.get('cols'), message.get('rows')
        if type(cols) is not int or type(rows) is not int or not 1 <= cols <= MAX_COLS or not 1 <= rows <= MAX_ROWS:
            raise BadRequest('invalid size')
        return ('resize', cols, rows)
    if kind == 'hangup':
        return ('hangup',)
    raise BadRequest('unknown control message')


def authorized(header, token_file=None):
    try:
        with open(token_file or TOKEN, 'rb') as f:
            token = f.read()
    except OSError:
        return False
    if not token or not header or not header.startswith('Bearer '):
        return False
    candidate = header[len('Bearer '):].encode()
    return hmac.compare_digest(hashlib.sha256(candidate).digest(), hashlib.sha256(token).digest())


class Screen:
    """Follows the output for the state a replay cannot carry: DEC private modes and the title."""
    CONTROL = re.compile(rb'\x1b\[\?([0-9;]{1,40})([hl])|\x1b\]([02]);([^\x07\x1b]{0,4096})(?:\x07|\x1b\\)')

    def __init__(self):
        self.modes = dict(TRACKED_MODES)
        self.title = ''
        self.tail = b''

    def feed(self, data):
        data = self.tail + data
        end = 0
        for match in self.CONTROL.finditer(data):
            end = match.end()
            if match[1] is not None:
                for part in match[1].split(b';'):
                    if part.isdigit() and int(part) in self.modes:
                        self.modes[int(part)] = match[2] == b'h'
            else:
                self.title = sanitize(match[4].decode('utf-8', 'replace'))[:TITLE_LIMIT]
        # Keep an unfinished sequence for the next chunk; one that cannot finish is dropped.
        start = data.rfind(b'\x1b', end)
        self.tail = data[start:] if start >= 0 and len(data) - start <= 4200 else b''
        if self.tail and self.CONTROL.match(self.tail):
            self.tail = b''

    def changed_modes(self):
        """The tracked modes that differ from a fresh terminal, as `{ "mode": set }`."""
        return {str(mode): value for mode, value in sorted(self.modes.items()) if value != TRACKED_MODES[mode]}


def sanitize(text):
    return ''.join(c for c in text if c.isprintable())


class Replay:
    """The newest output, addressed by its offset in the session's output stream."""

    def __init__(self, limit=REPLAY_BYTES):
        self.limit = limit
        self.buffer = bytearray()
        self.start = 0

    @property
    def end(self):
        return self.start + len(self.buffer)

    def append(self, data):
        self.buffer += data
        excess = len(self.buffer) - self.limit
        if excess > 0:
            del self.buffer[:excess]
            self.start += excess

    def since(self, offset):
        """(offset, data, reset) for a client that holds output up to `offset`.

        A client that holds nothing (None), or holds output no longer kept or never sent,
        gets everything kept and resets its terminal first. Kept output that begins inside a
        UTF-8 sequence or an escape sequence starts at the next line or escape instead.
        """
        if offset is not None and self.start <= offset <= self.end:
            return offset, bytes(self.buffer[offset - self.start:]), False
        skip = 0
        if self.start > 0:
            head = bytes(self.buffer[:512])
            marks = [i for i in (head.find(b'\n') + 1 if b'\n' in head else -1, head.find(b'\x1b')) if i >= 0]
            if marks:
                skip = min(marks)
            else:
                while skip < len(self.buffer) and 0x80 <= self.buffer[skip] < 0xC0:
                    skip += 1
        return self.start + skip, bytes(self.buffer[skip:]), True


def display_env(path=None):
    """The owner display's launch environment (`KEY='value'` lines), so GUI apps open on the phone."""
    env = {}
    try:
        with open(path or DISPLAY_ENV) as f:
            lines = f.read().splitlines()
    except OSError:
        return env
    for line in lines:
        try:
            words = shlex.split(line, comments=True)
        except ValueError:
            continue
        for word in words:
            key, sep, value = word.partition('=')
            if sep and re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*', key):
                env[key] = value
    return env


# What the service's own environment says about itself or its user, not about the computer.
NOT_INHERITED = {'HOME', 'USER', 'LOGNAME', 'SHELL', 'PWD', 'OLDPWD', 'SHLVL', '_', 'TERM', 'MAIL', 'INVOCATION_ID',
                 'JOURNAL_STREAM', 'SYSTEMD_EXEC_PID', 'NOTIFY_SOCKET', 'MANAGERPID', 'LISTEN_PID', 'LISTEN_FDS'}


def shell_environment(user, inherited=None):
    """The computer's environment (a container's GPU libraries, say), the owner display's, and a login's."""
    inherited = os.environ if inherited is None else inherited
    env = {k: v for k, v in inherited.items() if k not in NOT_INHERITED and not k.startswith('CABOOSE_TERMINAL_') and (k != 'LD_PRELOAD' or v)}
    env.update(display_env())
    runtime = f'/run/user/{user.pw_uid}'
    if os.path.isdir(runtime):
        env['XDG_RUNTIME_DIR'] = runtime
        if os.path.exists(f'{runtime}/bus'):
            env['DBUS_SESSION_BUS_ADDRESS'] = f'unix:path={runtime}/bus'
    env.update({
        'HOME': user.pw_dir, 'USER': user.pw_name, 'LOGNAME': user.pw_name, 'SHELL': user.pw_shell or '/bin/bash',
        'PATH': '/usr/local/bin:/usr/bin:/bin:/usr/local/games:/usr/games',
        'TERM': 'xterm-256color', 'COLORTERM': 'truecolor', 'TERM_PROGRAM': 'Caboose',
        'LANG': os.environ.get('LANG') or 'C.UTF-8',
    })
    return env


def set_size(fd, cols, rows):
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', rows, cols, 0, 0))


def controlling_terminal():
    # In the child, after setsid and the dup2 of the pseudo-terminal onto 0, 1 and 2.
    fcntl.ioctl(0, termios.TIOCSCTTY, 0)


class Session:
    def __init__(self, service, cols, rows):
        self.service = service
        self.id = secrets.token_hex(16)
        self.cols, self.rows = cols, rows
        self.created = int(time.time() * 1000)
        self.detached = time.monotonic()
        self.replay = Replay()
        self.screen = Screen()
        self.client = None
        self.outbox = bytearray()
        self.wake = asyncio.Event()
        self.reading = False
        self.exit = None
        self.ended = asyncio.Event()
        self.process = None
        self.master = None

    async def start(self):
        user = pwd.getpwuid(os.getuid())
        shell = user.pw_shell if user.pw_shell and os.access(user.pw_shell, os.X_OK) else '/bin/bash'
        master, slave = os.openpty()
        try:
            set_size(slave, self.cols, self.rows)
            os.set_blocking(master, False)
            os.set_inheritable(master, False)
            self.process = await asyncio.create_subprocess_exec(
                '-' + os.path.basename(shell), executable=shell, stdin=slave, stdout=slave, stderr=slave,
                cwd=user.pw_dir if os.path.isdir(user.pw_dir) else '/', env=shell_environment(user),
                start_new_session=True, preexec_fn=controlling_terminal)
        except BaseException:
            os.close(master)
            raise
        finally:
            os.close(slave)
        self.master = master
        self.resume_reading()
        asyncio.get_running_loop().create_task(self.watch())

    # Output ---------------------------------------------------------------------------------
    def resume_reading(self):
        if not self.reading and self.master is not None and self.exit is None:
            asyncio.get_running_loop().add_reader(self.master, self.readable)
            self.reading = True

    def pause_reading(self):
        if self.reading:
            asyncio.get_running_loop().remove_reader(self.master)
            self.reading = False

    def readable(self):
        try:
            data = os.read(self.master, READ_BYTES)
        except BlockingIOError:
            return
        except OSError as error:
            if error.errno != errno.EIO:
                raise
            data = b''
        if not data:
            # Every process holding the terminal closed it; the shell's exit follows.
            self.pause_reading()
            return
        self.output(data)

    def output(self, data):
        self.replay.append(data)
        self.screen.feed(data)
        if self.client is not None:
            self.outbox += data
            self.wake.set()
            if len(self.outbox) > HIGH:
                self.pause_reading()

    async def send_output(self, client):
        """Sends queued output to the attached client, at the pace the client reads it."""
        while self.client is client:
            await self.wake.wait()
            self.wake.clear()
            while self.outbox and self.client is client:
                chunk = bytes(self.outbox[:READ_BYTES])
                del self.outbox[:READ_BYTES]
                await client.send(chunk)
                if len(self.outbox) < LOW:
                    self.resume_reading()

    async def watch(self):
        code = await self.process.wait()
        # Whatever the shell wrote before it exited is still in the terminal.
        self.pause_reading()
        for _ in range(64):
            try:
                data = os.read(self.master, READ_BYTES)
            except OSError:
                break
            if not data:
                break
            self.output(data)
        self.exit = {'type': 'exit', 'code': code} if code >= 0 else {'type': 'exit', 'code': None, 'signal': -code}
        os.close(self.master)
        self.master = None
        self.service.sessions.pop(self.id, None)
        self.ended.set()
        self.wake.set()

    # Input ----------------------------------------------------------------------------------
    async def write(self, data):
        loop = asyncio.get_running_loop()
        view = memoryview(data)
        while view and self.master is not None:
            try:
                written = os.write(self.master, view)
                view = view[written:]
            except BlockingIOError:
                ready = loop.create_future()
                ended = asyncio.ensure_future(self.ended.wait())
                loop.add_writer(self.master, lambda: ready.done() or ready.set_result(None))
                try:
                    await asyncio.wait({ready, ended}, return_when=asyncio.FIRST_COMPLETED)
                finally:
                    ended.cancel()
                    if self.master is not None:
                        loop.remove_writer(self.master)
            except OSError:
                return

    def resize(self, cols, rows):
        self.cols, self.rows = cols, rows
        if self.master is not None:
            set_size(self.master, cols, rows)

    def redraw(self):
        """Has a full-screen program repaint, by changing the size and changing it back."""
        if self.master is None or self.rows < 2:
            return
        set_size(self.master, self.cols, self.rows - 1)
        asyncio.get_running_loop().call_later(0.05, lambda: self.master is not None and set_size(self.master, self.cols, self.rows))

    def hangup(self):
        if self.exit is not None or self.process is None:
            return
        try:
            os.killpg(self.process.pid, signal.SIGHUP)
        except ProcessLookupError:
            return
        asyncio.get_running_loop().call_later(5, self.kill)

    def kill(self):
        if self.exit is None:
            try:
                os.killpg(self.process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass

    # Listing --------------------------------------------------------------------------------
    def describe(self):
        command, cwd = None, None
        # The foreground program, and the directory it is in (the shell's when it has gone).
        pids = [self.process.pid] if self.process is not None else []
        try:
            if self.master is not None:
                pids.insert(0, os.tcgetpgrp(self.master))
        except OSError:
            pass
        for pid in pids:
            try:
                with open(f'/proc/{pid}/comm') as f:
                    command = command or sanitize(f.read().strip())[:64] or None
                cwd = cwd or sanitize(os.readlink(f'/proc/{pid}/cwd'))[:4096] or None
            except OSError:
                pass
        return {'id': self.id, 'title': self.screen.title, 'command': command, 'cwd': cwd, 'cols': self.cols,
                'rows': self.rows, 'created': self.created, 'attached': self.client is not None}


class Service:
    def __init__(self):
        self.sessions = {}

    async def open(self, cols, rows):
        if len(self.sessions) >= MAX_SESSIONS:
            detached = [s for s in self.sessions.values() if s.client is None]
            if not detached:
                return None
            # Make room by hanging up the session nobody has looked at for longest.
            oldest = min(detached, key=lambda s: s.detached)
            self.sessions.pop(oldest.id, None)
            oldest.hangup()
        session = Session(self, cols, rows)
        await session.start()
        self.sessions[session.id] = session
        return session

    def listing(self):
        return {'sessions': [s.describe() for s in sorted(self.sessions.values(), key=lambda s: s.created)]}

    async def serve_client(self, connection):
        from websockets.exceptions import ConnectionClosed
        try:
            cols, rows, session_id, offset = parse_attach(connection.request.path)
        except BadRequest as error:
            await connection.close(CLOSE_INVALID, str(error))
            return
        if session_id is None:
            session = await self.open(cols, rows)
            if session is None:
                await connection.close(1013, 'too many terminal sessions')
                return
        else:
            session = self.sessions.get(session_id)
            if session is None:
                await connection.close(4404, 'session ended')
                return
            session.resize(cols, rows)
        previous = session.client
        session.client = connection
        session.outbox.clear()
        session.resume_reading()
        if previous is not None:
            await previous.close(CLOSE_REPLACED, 'attached elsewhere')
        start, data, reset = session.replay.since(offset)
        hello = {'type': 'hello', 'session': session.id, 'offset': start, 'reset': reset}
        if reset:
            hello['modes'] = session.screen.changed_modes()
        tasks = []
        try:
            await connection.send(json.dumps(hello))
            for index in range(0, len(data), READ_BYTES):
                await connection.send(data[index:index + READ_BYTES])
            if reset and session.replay.start > 0 and any(session.screen.modes[m] for m in (47, 1047, 1049)):
                session.redraw()
            tasks = [asyncio.ensure_future(session.send_output(connection)),
                     asyncio.ensure_future(self.receive(connection, session)),
                     asyncio.ensure_future(session.ended.wait())]
            done, _ = await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
            for task in tasks:
                task.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)
            for task in done:
                if not task.cancelled() and task.exception() is not None:
                    raise task.exception()
            if session.exit is not None and session.client is connection:
                # Flush what the shell wrote last, then say how it ended.
                while session.outbox:
                    chunk = bytes(session.outbox[:READ_BYTES])
                    del session.outbox[:READ_BYTES]
                    await connection.send(chunk)
                await connection.send(json.dumps(session.exit))
                await connection.close(1000, 'exited')
        except ConnectionClosed:
            pass
        except BadRequest as error:
            await connection.close(CLOSE_INVALID, str(error))
        finally:
            for task in tasks:
                task.cancel()
            if session.client is connection:
                session.client = None
                session.detached = time.monotonic()
                session.outbox.clear()
                session.resume_reading()
                session.wake.set()

    async def receive(self, connection, session):
        async for message in connection:
            if session.client is not connection:
                return
            if isinstance(message, bytes):
                await session.write(message)
                continue
            control = parse_control(message)
            if control[0] == 'resize':
                session.resize(control[1], control[2])
            else:
                session.hangup()


def respond(connection, status, body=None):
    from websockets.datastructures import Headers
    from websockets.http11 import Response
    payload = json.dumps(body).encode() if body is not None else b''
    headers = Headers([('Content-Type', 'application/json'), ('Content-Length', str(len(payload))), ('Connection', 'close')])
    return Response(status.value, status.phrase, headers, payload)


def process_request(service):
    def check(connection, request):
        if not authorized(request.headers.get('Authorization')):
            return respond(connection, HTTPStatus.UNAUTHORIZED, {'error': 'unauthorized'})
        target = urlsplit(request.path)
        if target.path == '/sessions':
            return respond(connection, HTTPStatus.OK, service.listing())
        if target.path == '/hangup':
            session = service.sessions.get(parse_qs(target.query).get('session', [''])[0])
            if session is None:
                return respond(connection, HTTPStatus.NOT_FOUND, {'error': 'session ended'})
            session.hangup()
            return respond(connection, HTTPStatus.OK, {'hungUp': True})
        if target.path != '/':
            return respond(connection, HTTPStatus.NOT_FOUND, {'error': 'not found'})
        return None
    return check


async def main(host='0.0.0.0', port=PORT, ready=None):
    from websockets.asyncio.server import serve
    service = Service()
    async with serve(service.serve_client, host, port, process_request=process_request(service), compression=None,
                     max_size=1024 * 1024, ping_interval=20, ping_timeout=20) as server:
        if ready is not None:
            ready(server, service)
        stop = asyncio.get_running_loop().create_future()
        for sig in (signal.SIGTERM, signal.SIGINT):
            asyncio.get_running_loop().add_signal_handler(sig, lambda: stop.done() or stop.set_result(None))
        await stop
    # Closing each terminal hangs up its shell, as a dropped SSH connection would.
    for session in list(service.sessions.values()):
        session.hangup()


if __name__ == '__main__':
    asyncio.run(main())
