#!/usr/bin/env python3
"""Two cold disposable containers: synthetic Chromium profiles + real GNOME keyring.

Host: python3 check-dual-seat.py --image sha256:... --seccomp /path/to/caboose-seccomp.json
Requires an already-built integrated Caboose container image; never builds or pulls one.
"""
import argparse
import asyncio
import concurrent.futures
import hashlib
import http.server
import importlib.util
import json
import os
from pathlib import Path
import secrets
import subprocess
import sys
import threading
import time
import urllib.request
import uuid


def checked(args, **kwargs):
    return subprocess.run(args, check=True, timeout=60, **kwargs)


def as_owner(args, **kwargs):
    return checked(['runuser', '-u', 'caboose', '--', 'env', 'HOME=/home/caboose',
        'XDG_RUNTIME_DIR=/run/user/1000', 'DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus', *args], **kwargs)


def agent_secret(check_id):
    from gi.repository import Gio, GLib
    writers = []
    for proc in Path('/proc').iterdir():
        if not proc.name.isdecimal():
            continue
        try:
            first = (proc / 'cmdline').read_bytes().split(b'\0')[0]
        except (FileNotFoundError, PermissionError):
            continue
        if first.endswith(b'/gnome-keyring-daemon') or first == b'gnome-keyring-daemon':
            writers.append(int(proc.name))
    assert len(writers) == 1, 'Expected exactly one canonical GNOME keyring writer'
    bus = Gio.DBusConnection.new_for_address_sync('unix:path=/run/user/1000/agent-bus',
        Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION, None, None)
    root = '/org/freedesktop/secrets'
    def call(path, interface, method, signature, args):
        return bus.call_sync('org.freedesktop.secrets', path, 'org.freedesktop.Secret.' + interface,
            method, GLib.Variant(signature, args), None, Gio.DBusCallFlags.NONE, 10000, None).unpack()
    try:
        _, session = call(root, 'Service', 'OpenSession', '(sv)', ('plain', GLib.Variant('s', '')))
        unlocked, locked = call(root, 'Service', 'SearchItems', '(a{ss})', ({'caboose-keyring-check': check_id},))
        assert len(unlocked) == 1 and not locked, 'Synthetic canonical item unavailable through agent bus'
        value = call(unlocked[0], 'Item', 'GetSecret', '(o)', (session,))[0][2]
        assert bytes(value) == hashlib.sha256(('caboose-test-' + check_id).encode()).digest()
        request = Gio.DBusMessage.new_method_call('org.freedesktop.secrets', session,
            'org.freedesktop.Secret.Session', 'Close')
        assert request.get_body() is None
        reply, _ = bus.send_message_with_reply_sync(request, Gio.DBusSendMessageFlags.NONE, 10000, None)
        assert reply.get_message_type() == Gio.DBusMessageType.METHOD_RETURN, 'Session.Close failed'
        assert reply.get_body() is None, 'Session.Close returned an unexpected body'
        try:
            call(unlocked[0], 'Item', 'GetSecret', '(o)', (session,))
        except GLib.Error as error:
            assert Gio.DBusError.get_remote_error(error) == 'org.freedesktop.Secret.Error.NoSession'
        else:
            raise AssertionError('Closed GNOME session remained usable')
    finally:
        bus.close_sync(None)
    print('PASS: agent retrieves the synthetic GNOME item; bodyless Close returns empty and invalidates session')


def verify_windows(agent_count, check_id):
    # The control socket deliberately accepts only the compositor's UID. Keep
    # this whole polling loop in one owner process, not the root setup driver.
    assert Path('/.dockerenv').exists() and os.getuid() == 1000
    assert os.environ.get('CABOOSE_DISPOSABLE_ACCEPTANCE') == check_id
    assert Path('/home/caboose/.caboose-synthetic-seat-acceptance').read_text() == check_id
    assert agent_count in (1, 2)
    spec = importlib.util.spec_from_file_location('acceptance_seat', '/opt/caboose/seat.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    seats = {name: module.Seat('/run/user/1000/caboose-display/wayland-caboose-' + suffix + '/control.sock')
             for name, suffix in [('owner', '0'), ('agent', 'agent')]}
    for _ in range(450):
        windows = {name: seat.windows()['windows'] for name, seat in seats.items()}
        if (len(windows['owner']) == 1 and len(windows['agent']) == agent_count
            and all(name + '-PASS' in str(w.get('title', '')) for name, rows in windows.items() for w in rows)):
            return
        time.sleep(0.1)
    raise AssertionError('Synthetic browser windows/profile values did not remain on their own seats')


def inside(phase, check_id):
    assert Path('/.dockerenv').exists() and os.getuid() == 0
    assert os.environ.get('CABOOSE_DISPOSABLE_ACCEPTANCE') == check_id
    home = Path('/home/caboose')
    marker = home / '.caboose-synthetic-seat-acceptance'
    if phase == 'seed':
        assert not list(home.iterdir()), 'Refuse nonempty home; use a new volume with volume-nocopy'
        marker.write_text(check_id)
    else:
        assert marker.read_text() == check_id, 'Refuse a home not created by this acceptance run'
    os.chown(home, 1000, 1000)
    password = sys.stdin.buffer.read(65)
    assert len(password) == 64 and all(c in b'0123456789abcdef' for c in password)
    for path, owner, mode in [('/run/user/1000', 1000, 0o700), ('/run/caboose', 0, 0o755), ('/run/dbus', 0, 0o755)]:
        Path(path).mkdir(parents=True, exist_ok=True)
        os.chown(path, owner, owner)
        os.chmod(path, mode)
    token = Path('/run/caboose/display-token')
    token.write_text(secrets.token_hex(32))
    os.chmod(token, 0o600)
    os.chown(token, 1000, 1000)
    checked(['dbus-daemon', '--system', '--fork'])
    as_owner(['dbus-daemon', '--session', '--address=unix:path=/run/user/1000/bus', '--fork'])
    as_owner(['/usr/bin/python3', '/acceptance/check.py', phase if phase == 'seed' else 'verify', check_id], input=password)
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        list(pool.map(lambda action: checked(['caboose-session', action], stdout=subprocess.DEVNULL), ['start', 'start-agent']))
    checked(['caboose-session', 'ready'], stdout=subprocess.DEVNULL)
    as_owner(['/usr/bin/python3', __file__, '--agent-secret', check_id])

    class Page(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            seat = self.path.split('?', 1)[0].strip('/')
            if seat not in ('owner', 'agent'):
                self.send_error(404)
                return
            label = json.dumps(seat + '-synthetic-sign-in')
            seed = "localStorage.setItem('session', expected); document.cookie='session='+expected+'; Max-Age=3600; Path=/';" if phase == 'seed' else ''
            body = (f"<!doctype html><script>const expected={label};{seed}"
                "const ok=localStorage.getItem('session')===expected && document.cookie.split('; ').includes('session='+expected);"
                f"document.title='{seat}-'+(ok?'PASS':'FAIL');</script><p>Synthetic seat acceptance</p>").encode()
            self.send_response(200)
            self.send_header('Content-Type', 'text/html')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        def log_message(self, *args):
            pass
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 18991), Page)
    thread = threading.Thread(target=server.serve_forever)
    thread.start()
    children = []
    try:
        def launch(seat):
            command = '/usr/bin/chromium' if seat == 'owner' else '/usr/local/libexec/caboose-agent-seat-bin/chromium'
            envfile = '/run/caboose/' + ('display.env' if seat == 'owner' else 'agent-display.env')
            args = ['runuser', '-u', 'caboose', '--', 'env', 'HOME=/home/caboose',
                'DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/' + ('bus' if seat == 'owner' else 'agent-bus'),
                '/bin/sh', '-c', 'set -a; . "$1"; shift; exec "$@"', 'seat-check', envfile, command,
                '--no-first-run', '--no-default-browser-check', '--disable-background-networking',
                '--remote-debugging-port=' + ('18992' if seat == 'owner' else '18993'),
                '--new-window', 'http://127.0.0.1:18991/' + seat]
            child = subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            children.append(child)
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            list(pool.map(launch, ['owner', 'agent']))
        as_owner(['/usr/bin/python3', __file__, '--windows', '1', check_id])
        launch('agent')
        as_owner(['/usr/bin/python3', __file__, '--windows', '2', check_id])
        # Close each browser through its own test-only localhost debugging endpoint,
        # ensuring SQLite/local storage has a normal shutdown before the cold boot.
        async def close(port):
            import websockets
            with urllib.request.urlopen(f'http://127.0.0.1:{port}/json/version', timeout=5) as response:
                address = json.load(response)['webSocketDebuggerUrl']
            async with websockets.connect(address) as socket:
                await socket.send(json.dumps({'id': 1, 'method': 'Browser.close'}))
                try:
                    await asyncio.wait_for(socket.recv(), 5)
                except websockets.exceptions.ConnectionClosed:
                    pass
        for port in (18992, 18993):
            asyncio.run(close(port))
        for child in children:
            child.wait(timeout=15)
        as_owner(['/usr/bin/python3', '/acceptance/check.py', 'verify', check_id], input=password)
        as_owner(['/usr/bin/python3', __file__, '--agent-secret', check_id])
        print(f'PASS: {phase}: owner/agent Chromium windows, repeated agent launch, synthetic cookie/localStorage, canonical GNOME item')
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)
        # The host driver removes the entire disposable container on every path,
        # including any browser descendants, display daemons and timeout failures.


def host(image, seccomp, overlay_source=None):
    image_id = subprocess.check_output(['docker', 'image', 'inspect', '--format', '{{.Id}}', image], text=True).strip()
    assert image.startswith('sha256:') and image == image_id, 'Supply the full immutable local image ID; no pull/build occurs'
    seccomp = Path(seccomp).resolve(strict=True)
    check_id = uuid.uuid4().hex
    volume = 'caboose-seat-acceptance-' + check_id
    password = secrets.token_hex(32).encode()
    checked(['docker', 'volume', 'create', volume], stdout=subprocess.DEVNULL)
    try:
        for phase in ('seed', 'verify'):
            name = volume + '-' + phase
            try:
                overlay_args = []
                entrypoint = ['/usr/bin/python3', image, '/acceptance/check-dual-seat.py', '--inside', phase, check_id]
                if overlay_source:
                    source = Path(overlay_source).resolve(strict=True)
                    overlay_args = ['--mount', 'type=bind,source=' + str(source) + ',target=/seat-src,readonly',
                                    '--env', 'CABOOSE_ACCEPTANCE_OVERLAY=1']
                    entrypoint = ['/bin/sh', image, '-c',
                        'sh /acceptance/install-acceptance-overlay.sh /seat-src && exec /usr/bin/python3 /acceptance/check-dual-seat.py "$@"',
                        'acceptance-overlay', '--inside', phase, check_id]
                subprocess.run(['docker', 'run', '--name', name, '--init', '-i', '--network', 'none',
                    '--memory', '2g', '--cpus', '2', '--pids-limit', '256', '--shm-size', '256m',
                    '--security-opt', 'seccomp=' + str(seccomp), '--tmpfs', '/tmp:rw,nosuid,size=256m',
                    '--tmpfs', '/run:rw,nosuid,size=128m', '--env', 'CABOOSE_GPU=none',
                    '--env', 'CABOOSE_DISPOSABLE_ACCEPTANCE=' + check_id,
                    '--mount', 'type=volume,source=' + volume + ',target=/home/caboose,volume-nocopy',
                    '--mount', 'type=bind,source=' + str(Path(__file__).resolve().parent) + ',target=/acceptance,readonly',
                    *overlay_args, '--entrypoint', *entrypoint],
                    input=password, check=True, timeout=180)
            finally:
                checked(['docker', 'rm', '-f', name], stdout=subprocess.DEVNULL)
                assert subprocess.run(['docker', 'inspect', name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode != 0
    finally:
        checked(['docker', 'volume', 'rm', volume], stdout=subprocess.DEVNULL)
    print('PASS: both disposable containers reaped and synthetic home volume removed')


if __name__ == '__main__':
    if sys.argv[1:2] == ['--inside']:
        inside(*sys.argv[2:])
    elif sys.argv[1:2] == ['--agent-secret']:
        agent_secret(sys.argv[2])
    elif sys.argv[1:2] == ['--windows']:
        verify_windows(int(sys.argv[2]), sys.argv[3])
    else:
        parser = argparse.ArgumentParser(description=__doc__)
        parser.add_argument('--image', required=True)
        parser.add_argument('--seccomp', required=True)
        parser.add_argument('--overlay-source', help='Read-only source export plus out/ binaries; install the narrow overlay inside each test container')
        args = parser.parse_args()
        host(args.image, args.seccomp, args.overlay_source)
