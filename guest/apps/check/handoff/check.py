#!/usr/bin/python3
"""Exercise handoff, grants, bridge and local fallback in the disposable runtime container."""
import json
import os
import pwd
import runpy
import shutil
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path

protocol = runpy.run_path('/usr/local/bin/caboose-game-run')
owner = pwd.getpwnam('caboose')
home = Path(tempfile.mkdtemp(prefix='caboose-webview-check-'))
os.chown(home, owner.pw_uid, owner.pw_gid)
runtime = Path(f'/run/user/{owner.pw_uid}')
runtime.mkdir(parents=True, exist_ok=True)
os.chown(runtime, owner.pw_uid, owner.pw_gid)
os.chmod(runtime, 0o700)
processes = []
listener = None
link = None


def start(*args, **kwargs):
    proc = subprocess.Popen(args, **kwargs)
    processes.append(proc)
    return proc


def as_owner(*args, env):
    return start('runuser', '-u', 'caboose', '--', 'env', '-i', *[f'{k}={v}' for k, v in env.items()], *args,
                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def until(message, predicate, seconds=20):
    deadline = time.monotonic() + seconds
    last_error = None
    while time.monotonic() < deadline:
        try:
            if predicate():
                print('PASS ', message, flush=True)
                return
        except (OSError, urllib.error.URLError, RuntimeError) as error:
            last_error = error
        time.sleep(.1)
    raise AssertionError(f'{message}: {last_error}')


def read_exact(sock, length):
    data = b''
    while len(data) < length:
        part = sock.recv(length - len(data))
        if not part:
            raise RuntimeError('socket closed')
        data += part
    return data


def send_mode(mode, grant=None):
    message = {'mode': mode, 'window': 7}
    if grant:
        message['grant'] = grant
    link.sendall(protocol['frame'](protocol['MODE'], message))


def request(bridge, grant, operation, doc, raise_error=False, **fields):
    payload = json.dumps({'operation': operation, 'document': doc, 'grant': grant, **fields}).encode()
    req = urllib.request.Request(f'http://127.0.0.1:14700/webview/{bridge}', data=payload,
                                 headers={'Authorization': 'Bearer guest-test', 'Content-Type': 'application/json'})
    with urllib.request.urlopen(req, timeout=15) as response:
        result = json.load(response)
        if raise_error and not result.get('ok'):
            raise RuntimeError(result.get('error', 'bridge refused'))
        return result


try:
    app = home / 'Apps' / 'probe'
    app.mkdir(parents=True)
    (app / 'app.json').write_text(json.dumps({'name': 'Probe', 'capabilities': ['exec', 'files'], 'handoff': 'files'}))
    (app / 'index.html').write_text('<!doctype html><title>Probe</title><script src="probe.js"></script>')
    (app / 'probe.js').write_text("caboose.files.writeText('local-started', 'yes')")
    for path in [home / 'Apps', app, *app.iterdir()]:
        os.chown(path, owner.pw_uid, owner.pw_gid)
    legacy = home / 'Apps' / 'legacy'
    legacy.mkdir()
    (legacy / 'app.json').write_text(json.dumps({'name': 'Legacy', 'capabilities': ['files']}))
    (legacy / 'index.html').write_text('<!doctype html><title>Legacy</title><script src="probe.js"></script>')
    (legacy / 'probe.js').write_text("caboose.files.writeText('local-started', 'yes')")
    for path in [legacy, *legacy.iterdir()]:
        os.chown(path, owner.pw_uid, owner.pw_gid)
    os.symlink('/etc', home / 'escape')
    token = home / 'token'
    token.write_text('guest-test')
    os.chown(token, owner.pw_uid, owner.pw_gid)
    os.chmod(token, 0o600)
    socket_path = str(home / 'game.sock')
    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    listener.bind(socket_path)
    os.chown(socket_path, owner.pw_uid, owner.pw_gid)
    os.chmod(socket_path, 0o600)
    listener.listen(1)
    listener.settimeout(20)
    env = {'HOME': str(home), 'PATH': '/usr/local/bin:/usr/bin:/bin', 'DISPLAY': ':150',
           'XDG_RUNTIME_DIR': str(runtime), 'DBUS_SESSION_BUS_ADDRESS': f'unix:path={home}/bus'}
    xvfb = start('Xvfb', ':150', '-screen', '0', '1280x800x24', '-nolisten', 'tcp', stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    bus = as_owner('/usr/bin/dbus-daemon', '--session', '--address=' + env['DBUS_SESSION_BUS_ADDRESS'], '--nofork', env=env)
    until('session bus ready', lambda: (home / 'bus').exists())
    files_env = {**env, 'CABOOSE_FILES_ROOT': str(home), 'CABOOSE_FILES_TOKEN_FILE': str(token), 'CABOOSE_FILES_PORT': '14700',
                 'CABOOSE_BRIDGE_RUNTIME': str(runtime)}
    files_log = open(home / 'files.log', 'wb')
    files = start('runuser', '-u', 'caboose', '--', 'env', '-i', *[f'{k}={v}' for k, v in files_env.items()], '/usr/bin/python3', '/files/caboose-files.py', stdout=files_log, stderr=files_log)
    env['CABOOSE_GAME_SOCKET'] = socket_path
    legacy_process = as_owner('/usr/bin/python3', '/src/caboose-app', 'run', 'legacy', env=env)
    until('non-opted-in app starts locally', lambda: (home / '.local/share/caboose/apps/legacy/files/local-started').exists())
    listener.settimeout(1)
    try:
        unexpected, _ = listener.accept()
        unexpected.close()
        raise AssertionError('non-opted-in app contacted the handoff socket')
    except socket.timeout:
        print('PASS  non-opted-in app stays local', flush=True)
    legacy_process.terminate()
    legacy_process.wait(timeout=5)
    listener.settimeout(20)
    launched = as_owner('/usr/bin/python3', '/src/caboose-app', 'run', 'probe', env=env)
    link, _ = listener.accept()
    link.settimeout(10)
    header = read_exact(link, 5)
    assert header[0] == protocol['HELLO']
    message = protocol['decode'](read_exact(link, struct.unpack('<I', header[1:])[0]))
    bridge = message['bridge']
    assert message['kind'] == 'webview' and message['root'] == 'Apps/probe'
    until('app bridge socket created', lambda: (runtime / f'caboose-app-{bridge}.sock').exists())
    first, second, doc = 'a' * 32, 'b' * 32, 'c' * 32
    send_mode('handoff', first)
    until('first grant admitted', lambda: request(bridge, first, 'open', doc, revision=1, raise_error=True).get('ok') is True)
    result = request(bridge, first, 'call', doc, method='files.write', params={'path': 'state.txt', 'data': 'aGVsbG8='})
    assert result['ok']
    assert request(bridge, first, 'call', doc, method='files.read', params={'path': 'state.txt'})['value'] == 'aGVsbG8='
    assert not request(bridge, first, 'call', doc, method='notify', params={'title': 'no'})['ok']
    result = request(bridge, first, 'call', doc, method='exec', params={'argv': ['/bin/echo', 'hello']})
    assert result['ok'] and result['value']['stdout'] == 'hello\n'
    assert not request(bridge, first, 'call', doc, method='files.read', params={'path': '~/escape/passwd'})['ok']
    assert not request(bridge, first, 'call', doc, method='exec', params={'argv': ['/bin/pwd'], 'cwd': '~/escape'})['ok']
    spawned = request(bridge, first, 'call', doc, method='spawn', params={'argv': ['/bin/sleep', '60'], 'key': 'sleeper'})
    assert spawned['ok']
    previous_pid = spawned['value']['pid']
    (app / 'probe.js').write_text("caboose.files.writeText('local-started', 'yes')\n// edited")
    until('remote app edit requests a reload', lambda: any(event.get('type') == 'reload' for event in request(bridge, first, 'events', doc).get('value', [])))
    next_doc = 'e' * 32
    assert request(bridge, first, 'open', next_doc, revision=2)['ok']
    doc = next_doc
    def gone(process):
        try:
            os.kill(process, 0)
            return False
        except ProcessLookupError:
            return True
    until('reload stops the old document process', lambda: gone(previous_pid))
    spawned = request(bridge, first, 'call', doc, method='spawn', params={'argv': ['/bin/sleep', '60'], 'key': 'sleeper2'})
    assert spawned['ok']
    pid = spawned['value']['pid']
    print('PASS  bridge files, exec, capability gate and path fencing', flush=True)
    send_mode('local')
    until('fallback starts local WebKit', lambda: (home / '.local/share/caboose/apps/probe/files/local-started').exists())
    until('fallback stops the remote document process', lambda: gone(pid))
    assert (home / '.local/share/caboose/apps/probe/files/state.txt').read_text() == 'hello'
    send_mode('handoff', second)
    until('new grant admitted', lambda: request(bridge, second, 'open', doc, revision=1, raise_error=True).get('ok') is True)
    assert not request(bridge, first, 'open', doc, revision=999)['ok']
    later = 'd' * 32
    assert request(bridge, second, 'open', later, revision=2)['ok']
    assert not request(bridge, second, 'call', doc, method='files.read', params={'path': 'state.txt'})['ok']
    doc = later
    assert request(bridge, second, 'call', doc, method='files.read', params={'path': 'state.txt'})['value'] == 'aGVsbG8='
    print('PASS  takeover rejects stale grant and retains files', flush=True)
finally:
    if sys.exc_info()[0] is not None:
        log = home / '.local/share/caboose/apps/probe/console.log'
        if log.exists():
            print('APP LOG:', log.read_text(errors='replace'), flush=True)
        log = home / 'files.log'
        if log.exists():
            print('FILES LOG:', log.read_text(errors='replace'), flush=True)
    if link:
        link.close()
    if listener:
        listener.close()
    for proc in reversed(processes):
        if proc.poll() is None:
            proc.terminate()
    for proc in reversed(processes):
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()
    shutil.rmtree(home, ignore_errors=True)
