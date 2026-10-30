#!/usr/bin/python3
"""Disposable two-bus integration test. Requires Linux dbus-daemon and python3-gi."""
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import sys
import time
from gi.repository import Gio, GLib

spec = importlib.util.spec_from_file_location('forwarder', Path(__file__).with_name('secret-forwarder.py'))
f = importlib.util.module_from_spec(spec)
spec.loader.exec_module(f)


def admission_stress():
    from concurrent.futures import ThreadPoolExecutor
    proxy = f.Forwarder.__new__(f.Forwarder)
    proxy.admitted, proxy.admission_lock = 0, threading.Lock()
    replies, scheduled = [], []
    class Agent:
        def send_message(self, message, flags):
            replies.append(message)
    proxy.agent = Agent()
    original = GLib.idle_add
    GLib.idle_add = lambda *args: scheduled.append(args)
    try:
        def submit(_):
            request = Gio.DBusMessage.new_method_call(f.SERVICE, '/outside', 'org.freedesktop.Secret.Service', 'ReadAlias')
            request.set_sender(':1.99')
            request.set_serial(1)
            proxy.filter(None, request, True, None)
        with ThreadPoolExecutor(max_workers=8) as pool:
            list(pool.map(submit, range(1024)))
        assert len(scheduled) == proxy.admitted == 128
        assert len(replies) == 896
        assert all(reply.get_error_name().endswith('.LimitsExceeded') for reply in replies)
        for callback, request in scheduled:
            callback(request)
        assert proxy.admitted == 0
        def unavailable(*args):
            raise RuntimeError('synthetic scheduling failure')
        GLib.idle_add = unavailable
        submit(0)
        assert proxy.admitted == 0
    finally:
        GLib.idle_add = original
    print('PASS: 1024-call concurrent burst bounded to 128 queued+active calls; admission released')


def run():
    processes, connections = [], []
    loop = GLib.MainLoop()
    thread = threading.Thread(target=loop.run)
    thread.start()
    try:
        with tempfile.TemporaryDirectory(prefix='caboose-bus-test-') as tmp:
            def bus(name):
                config = Path(tmp) / (name + '.conf')
                config.write_text('<busconfig><type>session</type><auth>EXTERNAL</auth>'
                    '<listen>unix:tmpdir=' + tmp + '</listen><policy context="default">'
                    '<allow send_destination="*"/><allow receive_sender="*"/><allow own="*"/>'
                    '</policy></busconfig>')
                process = subprocess.Popen(['dbus-daemon', '--nofork', '--print-address=1', '--config-file=' + str(config)], stdout=subprocess.PIPE)
                processes.append(process)
                return process.stdout.readline().decode().strip()
            owner, agent = bus('owner'), bus('agent')
            def connection(address):
                conn = f.connect(address)
                connections.append(conn)
                return conn
            backend = connection(owner)
            assert f.bus_call(backend, 'GetConnectionUnixProcessID', '(s)', (f.DBUS,))[0] == processes[0].pid
            f.bus_call(backend, 'RequestName', '(su)', (f.SERVICE, 4))
            identities, prompts = {}, []
            def fake(bus, msg, incoming, data):
                if not incoming or msg.get_message_type() != Gio.DBusMessageType.METHOD_CALL:
                    return msg
                answer = msg.new_method_reply()
                member = msg.get_member()
                if member == 'OpenSession':
                    path = f.ROOT + '/session/s' + str(len(identities))
                    identities[path] = msg.get_sender()
                    answer.set_body(GLib.Variant('(vo)', (GLib.Variant('s', ''), path)))
                elif member == 'GetSecret':
                    session = msg.get_body().unpack()[0]
                    if identities.get(session) != msg.get_sender():
                        answer = msg.new_method_error_literal('org.freedesktop.Secret.Error.NoSession', 'synthetic')
                    else:
                        answer.set_body(GLib.Variant('((oayays))', ((session, [], list(b'synthetic-sign-in'), 'text/plain'),)))
                elif member == 'Prompt':
                    prompts.append(True)
                elif member == 'ReadAlias':
                    answer.set_body(GLib.Variant('(o)', (f.ROOT + '/collection/login',)))
                bus.send_message(answer, Gio.DBusSendMessageFlags.NONE)
                return None
            backend.add_filter(fake, None)
            def start_proxy():
                child = subprocess.Popen([sys.executable, __file__, '--proxy', owner, agent])
                processes.append(child)
                probe = connection(agent)
                for _ in range(200):
                    if child.poll() is not None:
                        raise AssertionError('proxy exited before readiness')
                    try:
                        f.bus_call(probe, 'GetNameOwner', '(s)', (f.SERVICE,))
                        return child
                    except GLib.Error:
                        time.sleep(0.01)
                raise AssertionError('proxy readiness timed out')
            proxy = start_proxy()
            a, b = connection(agent), connection(agent)
            def call(conn, method, body, interface='Service', path=f.ROOT):
                return conn.call_sync(f.SERVICE, path, 'org.freedesktop.Secret.' + interface,
                    method, body, None, Gio.DBusCallFlags.NONE, 5000, None).unpack()
            # Concurrent startup, distinct owner-side identities, same canonical service.
            from concurrent.futures import ThreadPoolExecutor
            with ThreadPoolExecutor(max_workers=2) as pool:
                sessions = list(pool.map(lambda conn: call(conn, 'OpenSession', GLib.Variant('(sv)', ('plain', GLib.Variant('s', ''))))[1], [a, b]))
            assert len(set(identities.values())) == 2
            for conn, session in zip([a, b], sessions):
                result = call(conn, 'GetSecret', GLib.Variant('(o)', (session,)), 'Item', f.ROOT + '/collection/login/item')
                assert bytes(result[0][2]) == b'synthetic-sign-in'
            try:
                call(b, 'GetSecret', GLib.Variant('(o)', (sessions[0],)), 'Item', f.ROOT + '/collection/login/item')
                raise AssertionError('session crossed client boundary')
            except GLib.Error as error:
                assert 'NoSession' in str(error)
            try:
                call(a, 'Prompt', GLib.Variant('(s)', ('',)), 'Prompt', f.ROOT + '/prompt/test')
                raise AssertionError('prompt was accepted')
            except GLib.Error as error:
                assert 'InteractionRequired' in str(error)
            assert not prompts
            assert call(a, 'ReadAlias', GLib.Variant('(s)', ('default',)))[0].endswith('/login')
            # Destination filtering never forwards owner UI/control methods.
            try:
                call(a, 'ReadAlias', GLib.Variant('(s)', ('default',)), path='/owner/window')
                raise AssertionError('non-secret path accepted')
            except GLib.Error as error:
                assert 'AccessDenied' in str(error)
            # A directed change signal returns only to its original agent client.
            received = threading.Event()
            wrong = []
            a.signal_subscribe(f.SERVICE, 'org.freedesktop.Secret.Collection', 'ItemChanged', None, None,
                Gio.DBusSignalFlags.NONE, lambda *args: received.set(), None)
            b.signal_subscribe(f.SERVICE, 'org.freedesktop.Secret.Collection', 'ItemChanged', None, None,
                Gio.DBusSignalFlags.NONE, lambda *args: wrong.append(True), None)
            # Bus roundtrips ensure match registrations precede the test signal.
            f.bus_call(a, 'GetId', '()', ())
            f.bus_call(b, 'GetId', '()', ())
            backend.emit_signal(identities[sessions[0]], f.ROOT + '/collection/login',
                'org.freedesktop.Secret.Collection', 'ItemChanged', GLib.Variant('(o)', (f.ROOT + '/collection/login/item',)))
            assert received.wait(5)
            assert not wrong
            # A second forwarder cannot replace the first or become a second writer.
            try:
                f.Forwarder(connection(agent), owner)
                raise AssertionError('duplicate service owner accepted')
            except RuntimeError:
                pass
            # Proxy crash discards upstream identities; retry uses a fresh session
            # against the same canonical store. Old session paths cannot be reused.
            proxy.kill()
            proxy.wait(timeout=5)
            # Roundtrip until the bus has observed disconnection, before replacement.
            for _ in range(200):
                try:
                    f.bus_call(a, 'GetNameOwner', '(s)', (f.SERVICE,))
                    time.sleep(0.01)
                except GLib.Error:
                    break
            proxy = start_proxy()
            try:
                call(a, 'GetSecret', GLib.Variant('(o)', (sessions[0],)), 'Item', f.ROOT + '/collection/login/item')
                raise AssertionError('old session survived proxy restart')
            except GLib.Error as error:
                assert 'NoSession' in str(error)
            session = call(a, 'OpenSession', GLib.Variant('(sv)', ('plain', GLib.Variant('s', ''))))[1]
            result = call(a, 'GetSecret', GLib.Variant('(o)', (session,)), 'Item', f.ROOT + '/collection/login/item')
            assert bytes(result[0][2]) == b'synthetic-sign-in'
            print('PASS: concurrent clients, session ownership, synthetic secret, prompt refusal, signals, singleton routing, crash/restart')
    finally:
        for conn in connections:
            if not conn.is_closed():
                conn.close_sync(None)
        loop.quit()
        thread.join(timeout=5)
        for process in reversed(processes):
            if process.poll() is None:
                process.terminate()
            process.wait(timeout=5)


if __name__ == '__main__':
    if sys.argv[1:2] == ['--proxy']:
        f.Forwarder(f.connect(sys.argv[3]), sys.argv[2])
        GLib.MainLoop().run()
    else:
        admission_stress()
        run()
