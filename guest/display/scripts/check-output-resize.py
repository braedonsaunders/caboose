#!/usr/bin/env python3
"""Check output changes on a PRIVATE empty compositor, never an owner's seat.

Requires GTK3 PyGObject and python websockets (sync API), already in the test image.
The harness supplies private launch environment, token, compositor PID and loopback
port in an isolated network namespace. No input is injected. All GTK windows belong
to this fixture, and all child processes/connections close on exit.
"""
import argparse
import json
import os
from pathlib import Path
import socket
import struct
import subprocess
import sys
import threading
import time


def encode(value):
    def head(major, n):
        if n < 24:
            return bytes([major * 32 + n])
        for tag, size in [(24, 1), (25, 2), (26, 4), (27, 8)]:
            if n < 1 << (size * 8):
                return bytes([major * 32 + tag]) + n.to_bytes(size, 'big')
        raise ValueError(n)
    if isinstance(value, bool):
        return b'\xf5' if value else b'\xf4'
    if isinstance(value, int):
        return head(0, value)
    if isinstance(value, float):
        return b'\xfb' + struct.pack('>d', value)
    if isinstance(value, str):
        raw = value.encode()
        return head(3, len(raw)) + raw
    if isinstance(value, list):
        return head(4, len(value)) + b''.join(map(encode, value))
    if isinstance(value, dict):
        fields = sorted((encode(k), encode(v)) for k, v in value.items())
        return head(5, len(fields)) + b''.join(k + v for k, v in fields)
    raise TypeError(type(value))


def decode(data, at=0):
    first = data[at]
    major, info = first >> 5, first & 31
    at += 1
    if major == 7 and info in (20, 21, 22):
        return {20: False, 21: True, 22: None}[info], at
    n = info
    if info >= 24:
        size = {24: 1, 25: 2, 26: 4, 27: 8}[info]
        n = int.from_bytes(data[at:at + size], 'big')
        at += size
    if major in (0, 1):
        return (n if major == 0 else -1 - n), at
    if major in (2, 3):
        value = data[at:at + n]
        return (None if major == 2 else value.decode()), at + n
    if major in (4, 5):
        result = [] if major == 4 else {}
        for _ in range(n):
            value, at = decode(data, at)
            if major == 4:
                result.append(value)
            else:
                result[value], at = decode(data, at)
        return result, at
    if major == 7 and info in (26, 27):
        return struct.unpack('>f' if info == 26 else '>d', n.to_bytes(4 if info == 26 else 8, 'big'))[0], at
    raise ValueError((major, info))


def gtk_client(path):
    windows, counts = {}, {}
    last_phase = None
    def publish(phase):
        nonlocal last_phase
        result = {}
        for kind, window in windows.items():
            native = window.get_window()
            state = native.get_state() if native else 0
            result[kind] = dict(size=list(window.get_size()), mapped=window.get_mapped(),
                                fullscreen=bool(state & Gdk.WindowState.FULLSCREEN),
                                maximized=bool(state & Gdk.WindowState.MAXIMIZED),
                                configures=counts[kind])
        pending = Path(path + '.pending')
        pending.write_text(json.dumps(dict(phase=phase, windows=result)))
        pending.replace(path)
        if phase != last_phase:
            print(json.dumps(dict(phase=phase, pid=os.getpid())), flush=True)
            last_phase = phase
        return True
    publish('importing-gtk')
    import gi
    gi.require_version('Gtk', '3.0')
    from gi.repository import Gtk, Gdk, GLib
    for kind in ('fullscreen', 'maximized', 'ordinary'):
        publish('creating-' + kind)
        window = Gtk.Window(title='caboose-output-fixture-' + kind)
        window.set_decorated(False)
        window.set_default_size(320, 240)
        window.add(Gtk.DrawingArea())
        counts[kind] = 0
        windows[kind] = window
        def configured(_window, _event, kind=kind):
            counts[kind] += 1
            return False
        window.connect('configure-event', configured)
        if kind == 'fullscreen':
            window.fullscreen()
        elif kind == 'maximized':
            window.maximize()
        publish('mapping-' + kind)
        window.show_all()
        publish('mapped-' + kind)
    GLib.timeout_add(25, lambda: publish('running'))
    # The supervisor has a tighter deadline; this also bounds an orphan after failure.
    GLib.timeout_add_seconds(20, lambda: (Gtk.main_quit(), False)[1])
    Gtk.main()
    for window in windows.values():
        window.destroy()


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--client')
    ap.add_argument('--control')
    ap.add_argument('--compositor-pid', type=int)
    ap.add_argument('--token-file')
    ap.add_argument('--port', type=int, default=15499)
    args = ap.parse_args()
    if args.client:
        gtk_client(args.client)
        return
    runtime = Path(os.environ['XDG_RUNTIME_DIR']).resolve()
    control, authority = Path(args.control).resolve(), Path(os.environ['XAUTHORITY']).resolve()
    assert control.is_relative_to(runtime) and authority.is_relative_to(runtime)
    assert Path(args.token_file).resolve().is_relative_to(runtime)
    assert os.environ['CABOOSE_DISPLAY_CONTROL'] == str(control)

    def peer(path):
        with socket.socket(socket.AF_UNIX) as s:
            s.settimeout(2)
            s.connect(str(path))
            return struct.unpack('3i', s.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))[0]
    assert peer(control) == args.compositor_pid
    assert peer(runtime / os.environ['WAYLAND_DISPLAY']) == args.compositor_pid
    display_name = os.environ['DISPLAY']
    assert display_name.startswith(':') and display_name[1:].isdigit()
    children = []
    for proc in Path('/proc').iterdir():
        if not proc.name.isdigit():
            continue
        try:
            stat = (proc / 'stat').read_text().split(') ', 1)[1].split()
            if int(stat[1]) == args.compositor_pid and (proc / 'comm').read_text().strip() == 'Xwayland':
                argv = (proc / 'cmdline').read_bytes().split(b'\0')
                assert display_name.encode() in argv and str(authority).encode() in argv
                children.append(int(proc.name))
        except FileNotFoundError:
            continue
    assert len(children) == 1
    assert peer('/tmp/.X11-unix/X' + display_name[1:]) in [args.compositor_pid, *children]

    def seat():
        with socket.socket(socket.AF_UNIX) as s:
            s.settimeout(2)
            s.connect(str(control))
            s.sendall(b'windows\n')
            raw = b''
            while b'\n' not in raw:
                part = s.recv(65536)
                assert part
                raw += part
                assert len(raw) < 1048576
        result = json.loads(raw.split(b'\n', 1)[0])
        assert result['ok']
        return result
    assert not seat()['windows'], 'Refusing nonempty seat'
    print(json.dumps(dict(paired_compositor=args.compositor_pid, paired_xwayland=children[0])), flush=True)

    from websockets.sync.client import connect
    connection = connect(f'ws://127.0.0.1:{args.port}', open_timeout=2, close_timeout=1, max_size=16 * 1024 * 1024)
    stop = threading.Event()
    errors, clients = [], []
    lock = threading.Lock()
    def send(kind, value):
        body = encode(value)
        with lock:
            connection.send(bytes([kind]) + struct.pack('<I', len(body)) + body)
    def monitor():
        try:
            while not stop.is_set():
                for display in (0, 1):
                    send(0x82, dict(display=display, t_us=int(time.monotonic() * 1e6)))
                try:
                    packet = connection.recv(timeout=.02)
                except TimeoutError:
                    continue
                assert isinstance(packet, bytes)
                while packet:
                    kind, size = packet[0], int.from_bytes(packet[1:5], 'little')
                    assert len(packet) >= size + 5
                    fields, _ = decode(packet[5:5 + size])
                    packet = packet[5 + size:]
                    if kind in (0x10, 0x11):
                        send(0x83, dict(id=fields['id'], pts_us=fields['pts_us'], decoded_us=0))
                    if kind == 0x7f:
                        raise AssertionError('Server ended fixture session')
        except Exception as e:
            if not stop.is_set():
                errors.append(str(e))
    reader = threading.Thread(target=monitor)
    def output(id, width, height):
        return dict(id=id, width=width, height=height, scale=1.0, refresh_hz=60.0, hdr=False)
    deadline = time.monotonic() + 18
    try:
        send(0x81, dict(version=0, token=Path(args.token_file).read_text().strip(), decoders=['h264'],
                        displays=[output(0, 1200, 800)]))
        reader.start()
        initial_deadline = min(deadline, time.monotonic() + 10)
        def snapshot():
            states = {backend: dict(pid=process.pid, exit=process.poll(),
                                   state=json.loads(path.read_text()) if path.exists() else None)
                      for backend, process, path in clients}
            windows = seat()['windows']
            assert all(w['pid'] in [p.pid for _, p, _ in clients] for w in windows), 'Foreign client'
            metadata = [{k: w[k] for k in ('id', 'pid', 'x11', 'display', 'rect')} for w in windows]
            return states, windows, dict(clients=states, windows=metadata)

        # Let one backend reach its event loop before starting the next. Partial
        # phases and seat state remain available if import/map/event-loop startup stalls.
        for backend in ('wayland', 'x11'):
            path = runtime / (backend + '-geometry.json')
            env = dict(os.environ, GDK_BACKEND=backend, GTK_CSD='0', NO_AT_BRIDGE='1')
            process = subprocess.Popen([sys.executable, __file__, '--client', str(path)], env=env,
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            clients.append((backend, process, path))
            last = None
            while time.monotonic() < initial_deadline:
                states, windows, last = snapshot()
                assert not errors, (errors, last)
                assert process.poll() is None, ('GTK client exited', last)
                state = states[backend]['state']
                if (state and state['phase'] == 'running' and len(state['windows']) == 3
                        and all(w['mapped'] for w in state['windows'].values())
                        and sum(w['pid'] == process.pid for w in windows) == 3):
                    print(json.dumps(dict(stage=backend + '-ready', **last)), flush=True)
                    break
                time.sleep(.025)
            else:
                raise AssertionError(('initial-readiness-' + backend, last))
        ordinary = {}
        identities = None
        def wait_geometry(stage, width, height, display=0, origin=0, until=None):
            nonlocal identities
            last = None
            until = min(deadline, time.monotonic() + 3) if until is None else until
            while time.monotonic() < until:
                states, windows, last = snapshot()
                assert not errors, (errors, last)
                assert all(p.poll() is None for _, p, _ in clients), ('GTK client exited', last)
                rows = {b: state['state']['windows'] if state['state'] else {} for b, state in states.items()}
                good = len(windows) == 6
                for backend, proc, _ in clients:
                    for kind in ('fullscreen', 'maximized', 'ordinary'):
                        row = rows[backend].get(kind)
                        if row is None:
                            good = False
                            continue
                        found = [w for w in windows if w['pid'] == proc.pid and w['title'] == 'caboose-output-fixture-' + kind]
                        if len(found) != 1:
                            good = False
                            continue
                        w = found[0]
                        good &= bool(w['x11']) == (backend == 'x11')
                        good &= row['fullscreen'] == (kind == 'fullscreen') and row['maximized'] == (kind == 'maximized')
                        if kind == 'ordinary':
                            if backend not in ordinary:
                                ordinary[backend] = dict(size=row['size'], rect=w['rect'])
                            good &= row['size'] == ordinary[backend]['size'] and w['rect'] == ordinary[backend]['rect']
                        else:
                            good &= row['size'] == [width, height] and w['rect'] == [origin, 0, width, height] and w['display'] == display
                if good:
                    now = sorted((w['id'], w['pid'], w['x11']) for w in windows)
                    if identities is None:
                        identities = now
                    assert now == identities, 'Window identities changed'
                    print(json.dumps(dict(stage=stage, **last)), flush=True)
                    return windows, rows
                time.sleep(.025)
            raise AssertionError((stage, last))
        windows, _ = wait_geometry('initial', 1200, 800, until=initial_deadline)
        send(0x87, dict(displays=[output(0, 800, 1200)]))
        wait_geometry('same-id-portrait', 800, 1200)
        # Settle toolkit events before checking a repeated identical announcement.
        time.sleep(.25)
        _, before = wait_geometry('unchanged-baseline', 800, 1200)
        send(0x87, dict(displays=[output(0, 800, 1200)]))
        time.sleep(.25)
        _, after = wait_geometry('unchanged-output', 800, 1200)
        assert before == after, 'Unchanged output generated additional client configure events'
        send(0x87, dict(displays=[output(0, 800, 1200), output(1, 640, 480)]))
        for w in windows:
            if not w['title'].endswith('-ordinary'):
                send(0x84, dict(id=w['id'], display=1))
        wait_geometry('secondary-output', 640, 480, 1, 800)
        send(0x87, dict(displays=[output(0, 600, 1200), output(1, 640, 480)]))
        wait_geometry('downstream-origin-shift', 640, 480, 1, 600)
        send(0x87, dict(displays=[output(0, 600, 1200)]))
        wait_geometry('removed-output-fallback', 600, 1200)
        print('PASS: Wayland and X11 fullscreen/maximized follow rotation, origin shift and removal; ordinary windows and unchanged output remain unchanged', flush=True)
    finally:
        for backend, process, _ in clients:
            if process.poll() is None:
                process.terminate()
            try:
                stdout, stderr = process.communicate(timeout=1)
            except subprocess.TimeoutExpired:
                process.kill()
                stdout, stderr = process.communicate(timeout=1)
            print(json.dumps(dict(backend=backend, pid=process.pid, exit=process.returncode,
                                  stdout=stdout.decode(errors='replace'), stderr=stderr.decode(errors='replace'))), flush=True)
        stop.set()
        connection.close()
        if reader.ident is not None:
            reader.join(timeout=2)
        assert not reader.is_alive(), 'Fixture websocket reader did not exit'
        assert not errors, errors


if __name__ == '__main__':
    main()
