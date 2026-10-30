#!/usr/bin/env python3
"""Compare core-wheel delivery through XTest and Caboose on a PRIVATE empty seat.

Source that seat's launch environment and pass its explicit --control socket.
Creates its own X11 parent/child, selects core pointer events ONLY on that child,
then checks one direct-X wheel pulse and two independent compositor wheel pulses.
Optional XI2 selection is confined to the owned child. No app names or
keyboard/focus manipulation.
Never run against an owner's seat. The fixture closes both windows on exit.
"""
import argparse
import ctypes as C
import json
import os
from pathlib import Path
import struct
import select
import socket
import time

P, U, I = C.c_void_p, C.c_ulong, C.c_int

class Button(C.Structure):
    _fields_ = [('type', I), ('serial', U), ('send', I), ('display', P),
                ('window', U), ('root', U), ('child', U), ('time', U),
                ('x', I), ('y', I), ('root_x', I), ('root_y', I),
                ('state', C.c_uint), ('button', C.c_uint), ('same_screen', I)]

class Event(C.Union):
    _fields_ = [('type', I), ('button', Button), ('pad', C.c_long * 24)]


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--control', required=True)
    ap.add_argument('--compositor-pid', required=True, type=int)
    ap.add_argument('--record-oracle', action='store_true')
    ap.add_argument('--xi2-oracle', choices=('observe', 'switching', 'stable'),
                    help='Add XI2/class/RECORD checks and optionally require baseline loss or consumption')
    args = ap.parse_args()

    def seat(command):
        with socket.socket(socket.AF_UNIX) as s:
            s.settimeout(3)
            s.connect(args.control)
            s.sendall((command + '\n').encode())
            reply = b''
            while b'\n' not in reply:
                chunk = s.recv(65536)
                assert chunk, 'Control connection closed'
                reply += chunk
                assert len(reply) <= 1_048_576, 'Unexpected control response size'
        result = json.loads(reply.split(b'\n', 1)[0])
        assert result.get('ok'), 'Control request refused'
        return result

    # Prove pairing BEFORE opening/creating any X resource. The private harness
    # supplies its own compositor PID; both listening sockets must belong to it
    # or its directly spawned Xwayland, using that same private authority file.
    runtime = Path(os.environ['XDG_RUNTIME_DIR']).resolve()
    control = Path(args.control).resolve()
    authority = Path(os.environ['XAUTHORITY']).resolve()
    assert control.is_relative_to(runtime) and authority.is_relative_to(runtime)
    assert os.environ['CABOOSE_DISPLAY_CONTROL'] == str(control)
    display_name = os.environ['DISPLAY']
    assert display_name.startswith(':') and display_name[1:].isdigit()
    def peer(path):
        with socket.socket(socket.AF_UNIX) as connection:
            connection.settimeout(3)
            connection.connect(str(path))
            return struct.unpack('3i', connection.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))[0]
    assert peer(control) == args.compositor_pid, 'Control socket belongs to another process'
    children = []
    for proc in Path('/proc').iterdir():
        if not proc.name.isdigit():
            continue
        try:
            stat = (proc / 'stat').read_text().split(') ', 1)[1].split()
            argv = (proc / 'cmdline').read_bytes().split(b'\0')
            if int(stat[1]) == args.compositor_pid and (proc / 'comm').read_text().strip() == 'Xwayland':
                assert display_name.encode() in argv and str(authority).encode() in argv
                children.append(int(proc.name))
        except FileNotFoundError:
            continue
    assert len(children) == 1, 'Private compositor must own exactly one matching Xwayland'
    assert peer('/tmp/.X11-unix/X' + display_name[1:]) in [args.compositor_pid, *children]
    print(json.dumps({'paired_compositor': args.compositor_pid, 'paired_xwayland': children[0]}), flush=True)
    assert not seat('windows')['windows'], 'Refusing nonempty seat; use a disposable compositor'
    X = C.CDLL('libX11.so.6')
    T = C.CDLL('libXtst.so.6')
    X.XInitThreads.argtypes, X.XInitThreads.restype = [], I
    assert X.XInitThreads(), 'Xlib thread initialization failed'
    for name, arguments, result in [
        ('XOpenDisplay', [C.c_char_p], P), ('XDefaultRootWindow', [P], U),
        ('XCreateSimpleWindow', [P,U,I,I,C.c_uint,C.c_uint,C.c_uint,U,U], U),
        ('XMapWindow', [P,U], I), ('XDestroyWindow', [P,U], I),
        ('XCloseDisplay', [P], I), ('XSelectInput', [P,U,C.c_long], I),
        ('XSync', [P,I], I), ('XPending', [P], I),
        ('XNextEvent', [P,C.POINTER(Event)], I), ('XConnectionNumber', [P], I),
        ('XQueryPointer', [P,U,C.POINTER(U),C.POINTER(U),C.POINTER(I),C.POINTER(I),
                           C.POINTER(I),C.POINTER(I),C.POINTER(C.c_uint)], I),
    ]:
        f = getattr(X, name)
        f.argtypes, f.restype = arguments, result
    T.XTestFakeButtonEvent.argtypes = [P,C.c_uint,I,U]
    T.XTestFakeButtonEvent.restype = I
    display = X.XOpenDisplay(None)
    assert display, 'Cannot connect to the private Xwayland'
    parent = 0
    recorder = None
    xi = None
    results = []
    try:
        parent = X.XCreateSimpleWindow(display, X.XDefaultRootWindow(display),
                                      0, 0, 320, 240, 0, 0, 0)
        child = X.XCreateSimpleWindow(display, parent, 16, 16, 288, 208, 0, 0, 0)
        # This client OWNS this child. No foreign window's selection is modified.
        X.XSelectInput(display, child, (1 << 2) | (1 << 3) | (1 << 6))
        X.XMapWindow(display, child)
        X.XMapWindow(display, parent)
        X.XSync(display, 0)
        deadline = time.monotonic() + 5
        target = None
        while time.monotonic() < deadline:
            windows = seat('windows')['windows']
            assert all(w['x11'] == parent for w in windows), 'Another client appeared; stop'
            target = next((w for w in windows if w['x11'] == parent), None)
            if target:
                break
            time.sleep(.02)
        assert target, 'Fixture was not mapped by the compositor'
        x, y = target['rect'][0] + 64, target['rect'][1] + 64
        moved = seat(f'move {x} {y}')
        assert moved['window'] == target['id'], 'Wrong control/X display pairing'

        def collect(seconds=.35):
            deadline = time.monotonic() + seconds
            events = []
            while time.monotonic() < deadline:
                if not X.XPending(display):
                    select.select([X.XConnectionNumber(display)], [], [],
                                  max(0, deadline - time.monotonic()))
                    continue
                event = Event()
                X.XNextEvent(display, C.byref(event))
                if event.type in (4, 5):
                    b = event.button
                    assert b.window == child, 'Unexpected recipient'
                    events.append({'kind': 'core', 'type': b.type, 'button': b.button, 'time': b.time,
                                   'recipient': b.window})
                elif event.type == 35 and xi:
                    row = xi.event(event)
                    if row is not None:
                        events.append(row)
                assert len(events) <= 256, 'Fixture event limit exceeded'
            return events

        def pointer_position():
            root, under = U(), U()
            rx, ry, lx, ly, buttons = I(), I(), I(), I(), C.c_uint()
            assert X.XQueryPointer(display, child, C.byref(root), C.byref(under), C.byref(rx),
                                   C.byref(ry), C.byref(lx), C.byref(ly), C.byref(buttons))
            row = dict(root_xy=[rx.value, ry.value], local_xy=[lx.value, ly.value],
                       child=under.value, buttons=buttons.value)
            assert row['root_xy'] == [x, y] and row['local_xy'] == [48, 48], row
            assert not buttons.value and not under.value, row
            return row

        collect()  # Drain the positioning motion before comparing wheel delivery.
        if args.record_oracle or args.xi2_oracle:
            from x11_record import Recorder
            recorder = Recorder(parent)
            print(json.dumps({'record_registered': recorder.registered}), flush=True)
        pressed = T.XTestFakeButtonEvent(display, 5, 1, 0)
        released = T.XTestFakeButtonEvent(display, 5, 0, 0)
        X.XSync(display, 0)
        assert pressed and released, 'XTest request rejected'
        results.append({'path': 'direct-x', 'events': collect()})
        # Every control scroll includes pointer motion even at the unchanged anchor.
        # Repeat separately to expose stale focus or implicit-grab state across frames.
        for number in range(2):
            response = seat(f'scroll {x} {y} 0 1')
            assert response['window'] == target['id'], 'Wrong compositor target'
            results.append({'path': f'wayland-wheel-{number + 1}', 'events': collect()})
        print(json.dumps({'parent': parent, 'child': child, 'results': results}), flush=True)
        expected = [(4, 5), (5, 5)]
        for result in results:
            actual = [(e['type'], e['button']) for e in result['events']]
            assert actual == expected, f"{result['path']}: expected one core press/release pair; got {actual}"
        print('PASS: XTest and both compositor wheel frames deliver one core wheel pair')
        if recorder:
            recorder.close()
            print(json.dumps({'record_events': recorder.events, 'record_categories': recorder.categories,
                              'record_errors': recorder.errors}), flush=True)
            expected_events = [(e['type'], e['button'], e['time'], e['recipient'])
                               for r in results for e in r['events']]
            recorded = [(e['type'], e['button'], e['time'], e['recipient']) for e in recorder.events
                        if e['kind'] == 'core' and e['type'] in (4, 5)]
            assert not recorder.errors, 'RECORD callback errors'
            assert recorded == expected_events, f'RECORD oracle differs: {recorded} != {expected_events}'
            print('PASS: RECORD sees every core wheel pair received by the owned X client')
        if args.xi2_oracle:
            from x11_record import Recorder
            from x11_scroll_xi2 import XI2, BaselineConsumer, wheel_sample, assert_wheel_delta
            xi = XI2(X, display, child)
            xi.select_owned()
            collect()  # Finish selection before starting the oracle.
            devices = xi.devices()
            consumer = BaselineConsumer(devices)
            recorder = Recorder(3, recipients={child})  # AllClients, as in the live reader.
            print(json.dumps({'xi_version': xi.version, 'devices': devices,
                              'pointer_before': pointer_position(),
                              'record_registered': recorder.registered}), flush=True)
            xi_results = []
            for number in range(2):
                response = seat(f'scroll {x} {y} 0 1')
                assert response['window'] == target['id']
                events = collect()
                current_devices = xi.devices()
                row = dict(path=f'xi-wayland-wheel-{number + 1}', events=events,
                           sample=wheel_sample(events, current_devices),
                           consumer_offsets=consumer.consume(events),
                           pointer_after=pointer_position(), devices_after=current_devices)
                xi_results.append(row)
                print(json.dumps(row), flush=True)
            recorder.close()
            print(json.dumps({'xi_record_events': recorder.events,
                              'xi_record_categories': recorder.categories,
                              'xi_record_errors': recorder.errors}), flush=True)
            delta = assert_wheel_delta(xi_results[0]['sample'], xi_results[1]['sample'])
            expected_xi = [(e['type'], e['button'], e['time'], e['recipient'])
                           for r in xi_results for e in r['events'] if e['kind'] == 'XI']
            actual_xi = [(e['type'], e['button'], e['time'], e['recipient'])
                         for e in recorder.events if e['kind'] == 'XI']
            assert expected_xi, 'Owned XI2 client received nothing'
            assert not recorder.errors and actual_xi == expected_xi, (actual_xi, expected_xi)
            assert all(not any(e['kind'] == 'core' for e in r['events']) for r in xi_results), \
                'Unexpected duplicate core delivery while XI2 selection is active'
            print('PASS: XI2 values advance one class increment and RECORD matches received pointer headers')
            offsets = [r['consumer_offsets'] for r in xi_results]
            if args.xi2_oracle == 'switching':
                assert offsets == [[0.0], [0.0]], offsets
                for r in xi_results:
                    switches = [e['source'] for e in r['events'] if e['kind'] == 'changed' and e['reason'] == 1]
                    assert len(set(switches)) >= 2, switches
                print('PASS: current-path negative control loses both deltas after source switches')
            elif args.xi2_oracle == 'stable':
                assert offsets == [[0.0], [-1.0]], offsets
                assert not any(e['kind'] == 'changed' and e['reason'] == 1 for e in xi_results[1]['events'])
                print('PASS: stable source preserves baseline and consumes the second wheel increment')
            print(json.dumps({'smooth_delta': delta, 'consumer_offsets': offsets}), flush=True)
    finally:
        if recorder:
            recorder.close()
        if parent:
            X.XDestroyWindow(display, parent)  # Also destroys the owned child.
            X.XSync(display, 0)
        X.XCloseDisplay(display)


if __name__ == '__main__':
    main()
