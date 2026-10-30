#!/usr/bin/env python3
"""Actual Chromium content scrolling on an OWNED private X11/Wayland seat.

Uses only the existing installed Chromium and Python websockets; no downloads.
The page reports its own event counts/scrollY through a fixture-only window title.
Run inside the disposable capped harness with a 20-second process deadline.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import shutil
import signal
import socket
import struct
import subprocess
import threading
import time


def frame_ack(kind, fields):
    """Only encoded frames have presentation timestamps and consume ACK credit."""
    if kind == 0x10:
        return dict(id=fields['id'], pts_us=fields['pts_us'], decoded_us=0)
    return None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--control', required=True)
    parser.add_argument('--compositor-pid', type=int, required=True)
    parser.add_argument('--token-file', required=True)
    parser.add_argument('--port', type=int, default=15499)
    parser.add_argument('--scale', type=float, default=1.5)
    parser.add_argument('--precise-delta', type=float, default=24.0)
    args = parser.parse_args()
    assert 0 < args.scale <= 4 and 0 < args.precise_delta <= 120
    runtime = Path(os.environ['XDG_RUNTIME_DIR']).resolve()
    control = Path(args.control).resolve()
    authority = Path(os.environ['XAUTHORITY']).resolve()
    token = Path(args.token_file).resolve()
    assert all(p.is_relative_to(runtime) for p in (control, authority, token))
    assert str(control) == os.environ['CABOOSE_DISPLAY_CONTROL']
    display_name = os.environ['DISPLAY']
    assert display_name.startswith(':') and display_name[1:].isdigit()

    def peer(path):
        with socket.socket(socket.AF_UNIX) as s:
            s.settimeout(2)
            s.connect(str(path))
            return struct.unpack('3i', s.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))[0]
    assert peer(control) == args.compositor_pid
    assert peer(runtime / os.environ['WAYLAND_DISPLAY']) == args.compositor_pid
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
                chunk = s.recv(65536)
                assert chunk
                raw += chunk
                assert len(raw) < 1048576
        result = json.loads(raw.split(b'\n', 1)[0])
        assert result['ok']
        return result['windows']
    assert not seat(), 'Refusing nonempty seat'
    browser = shutil.which('chromium')
    assert browser, 'Existing Chromium missing; do not install'
    print(json.dumps({'paired_compositor': args.compositor_pid, 'paired_xwayland': children[0],
                      'chromium': subprocess.check_output([browser, '--version'], text=True, timeout=2).strip()}), flush=True)

    # Reuse the existing display fixture's protocol encoder/decoder, not a second codec.
    spec = importlib.util.spec_from_file_location('output_fixture', Path(__file__).with_name('check-output-resize.py'))
    codec = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(codec)
    from websockets.sync.client import connect
    connection = connect(f'ws://127.0.0.1:{args.port}', open_timeout=2, close_timeout=1,
                         max_size=16 * 1024 * 1024)
    stop = threading.Event()
    errors = []
    lock = threading.Lock()

    def send(kind, value):
        body = codec.encode(value)
        with lock:
            connection.send(bytes([kind]) + struct.pack('<I', len(body)) + body)

    def monitor():
        try:
            while not stop.is_set():
                send(0x82, dict(display=0, t_us=int(time.monotonic() * 1e6)))
                try:
                    packet = connection.recv(timeout=.02)
                except TimeoutError:
                    continue
                while packet:
                    kind, size = packet[0], int.from_bytes(packet[1:5], 'little')
                    assert len(packet) >= 5 + size
                    fields, _ = codec.decode(packet[5:5 + size])
                    packet = packet[5 + size:]
                    ack = frame_ack(kind, fields)
                    if ack is not None:
                        send(0x83, ack)
                    assert kind != 0x7f, 'Private session rejected'
        except Exception as error:
            if not stop.is_set():
                errors.append(str(error))
    reader = threading.Thread(target=monitor)
    process = None
    deadline = time.monotonic() + 17
    try:
        send(0x81, dict(version=0, token=token.read_text().strip(), decoders=['h264'],
                       displays=[dict(id=0, width=1200, height=900, scale=args.scale, refresh_hz=60.0, hdr=False)]))
        reader.start()
        for backend in ('x11', 'wayland'):
            profile = runtime / ('chromium-' + backend)
            log = (runtime / ('chromium-' + backend + '.log')).open('w')
            process = subprocess.Popen([browser, '--ozone-platform=' + backend, '--no-sandbox',
                                        '--disable-gpu', '--no-first-run', '--no-default-browser-check',
                                        '--disable-background-networking', '--disable-dev-shm-usage',
                                        '--disable-features=Translate', '--disable-smooth-scrolling',
                                        '--user-data-dir=' + str(profile), '--window-size=600,400',
                                        '--app=' + Path(__file__).with_name('pages').joinpath('pointer-scroll.html').as_uri()],
                                       stdout=log, stderr=log, start_new_session=True)
            try:
                def snapshot():
                    windows = seat()
                    assert len(windows) <= 1, 'Unexpected extra window in private seat'
                    if not windows:
                        return None, None
                    w = windows[0]
                    title = w.get('title', '')
                    if not title.startswith('pointer-fixture:{'):
                        return w, None
                    assert bool(w['x11']) == (backend == 'x11')
                    assert w['scale'] == args.scale
                    return w, json.loads(title.removeprefix('pointer-fixture:'))

                def wait_for(predicate, seconds=1.5):
                    until = min(deadline, time.monotonic() + seconds)
                    last = (None, None)
                    while time.monotonic() < until:
                        assert process.poll() is None, 'Private browser exited'
                        assert not errors, errors
                        last = snapshot()
                        if last[1] and predicate(*last):
                            return last
                        time.sleep(.025)
                    raise AssertionError((backend, 'condition timed out', last))

                window, initial = wait_for(lambda _w, s: s['ready'], 5)
                identifier = window['id']
                def pointer(x, y, buttons=0, scroll=None):
                    w, _ = snapshot()
                    assert w['id'] == identifier and min(w['rect'][2:]) > 200
                    message = dict(id=identifier, x=x * w['scale'], y=y * w['scale'], buttons=buttons)
                    if scroll:
                        message['scroll'] = scroll
                    send(0x92, message)
                pointer(140, 160)
                _, moved = wait_for(lambda _w, s: s['moves'] > initial['moves'])
                pointer(160, 176)
                _, moved_again = wait_for(lambda _w, s: s['moves'] > moved['moves'])
                assert moved_again['x'] > moved['x'] and moved_again['y'] > moved['y']
                pointer(160, 176, buttons=1)
                pointer(168, 184, buttons=1)
                pointer(168, 184, buttons=0)
                _, clicked = wait_for(lambda _w, s: s['down'] == 1 and s['up'] == 1 and s['dragMoves'] > 0)
                for _ in range(3):
                    pointer(160, 176, scroll=dict(dx=0.0, dy=1.0, precise=False))
                    time.sleep(.08)
                _, wheeled = wait_for(lambda _w, s: s['scrollY'] > clicked['scrollY'] and s['wheels'] > clicked['wheels'])
                for n in range(3):
                    pointer(160 + n * 3, 176 + n * 2, scroll=dict(dx=0.0, dy=args.precise_delta, precise=True))
                    time.sleep(.08)
                _, precise = wait_for(lambda _w, s: s['scrollY'] > wheeled['scrollY'] and s['wheels'] > wheeled['wheels'])
                print(json.dumps(dict(backend=backend, id=identifier, scale=window['scale'],
                                      precise_input=dict(samples=3, dy=args.precise_delta),
                                      moved=moved, moved_again=moved_again, clicked=clicked,
                                      wheel=wheeled, precise=precise)), flush=True)
                print('PASS: ' + backend + ' content scrolls for wheel and precise input; motion/buttons preserved', flush=True)
            finally:
                try:
                    os.killpg(process.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                if process.poll() is None:
                    try:
                        process.wait(timeout=1)
                    except subprocess.TimeoutExpired:
                        os.killpg(process.pid, signal.SIGKILL)
                        process.wait(timeout=1)
                try:
                    os.killpg(process.pid, signal.SIGKILL)  # Remaining children in our process group only.
                except ProcessLookupError:
                    pass
                process = None
                log.close()
            until = min(deadline, time.monotonic() + 1)
            while seat() and time.monotonic() < until:
                time.sleep(.025)
            assert not seat(), 'Private browser window did not disappear'
    finally:
        stop.set()
        if reader.ident is not None:
            reader.join(1)
        connection.close()
        if reader.ident is not None:
            reader.join(1)
            assert not reader.is_alive(), 'Private protocol reader did not exit'


if __name__ == '__main__':
    main()
