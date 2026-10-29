#!/usr/bin/python3
"""End-to-end check of the native bridge on a running computer, as the owner on the owner's
session bus (check.sh runs it). It plays the host's part itself: it drains and answers file
requests with caboose-bridge, so no phone or host is needed."""
import json
import os
import subprocess
import sys
import threading
import time

sys.path.insert(0, '/opt/caboose/bridge')
import bridgecore as core  # noqa: E402

import gi  # noqa: E402
gi.require_version('Gio', '2.0')
from gi.repository import Gio, GLib  # noqa: E402

BRIDGE = '/usr/local/bin/caboose-bridge'
bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
failures = []


def check(ok, message):
    print(('ok    ' if ok else 'FAIL  ') + message)
    if not ok:
        failures.append(message)


def bridge(*args):
    return subprocess.run([BRIDGE, *args], check=True, capture_output=True, text=True).stdout


def portal_call(interface, method, args, reply):
    return bus.call_sync('org.freedesktop.portal.Desktop', '/org/freedesktop/portal/desktop', interface, method,
                         args, GLib.VariantType(reply), Gio.DBusCallFlags.NONE, 10000, None).unpack()


def color_scheme():
    return portal_call('org.freedesktop.portal.Settings', 'ReadOne', GLib.Variant('(ss)', ('org.freedesktop.appearance', 'color-scheme')), '(v)')[0]


def appearance():
    before = core.read_json(core.APPEARANCE)
    try:
        for scheme, value in (('light', 2), ('dark', 1)):
            bridge('appearance', json.dumps({'colorScheme': scheme, 'accent': '#FF9500', 'contrast': 'normal', 'reducedMotion': False, 'textScale': 1}))
            deadline = time.time() + 5
            while time.time() < deadline and color_scheme() != value:
                time.sleep(0.2)
            check(color_scheme() == value, f'the Settings portal reports {scheme} after caboose-bridge appearance')
        theme = portal_call('org.freedesktop.portal.Settings', 'ReadOne', GLib.Variant('(ss)', ('org.gnome.desktop.interface', 'gtk-theme')), '(v)')[0]
        check(theme.endswith('-Dark') or theme.endswith('-dark'), f'GTK reads a dark theme through the portal ({theme})')
    finally:
        if before is not None:
            core.write_json(core.APPEARANCE, before)


class Host(threading.Thread):
    """The host's drain loop: presence, claiming, and one answer per request."""

    def __init__(self, answer):
        super().__init__(daemon=True)
        self.answer, self.stop, self.seen = answer, False, []

    def run(self):
        while not self.stop:
            drained = json.loads(bridge('drain'))
            for request in drained['requests']:
                self.seen.append(request)
                bridge('respond', json.dumps(self.answer(request)))
            time.sleep(0.5)


def file_chooser(method, options, answer):
    """Calls the FileChooser portal as an application would; returns (response, results, requests seen)."""
    host = Host(answer)
    host.start()
    time.sleep(1)  # the phone is present once the host has drained
    loop = GLib.MainLoop()
    outcome = {}
    token = f'cabooscheck{os.getpid()}'
    sender = bus.get_unique_name()[1:].replace('.', '_')
    handle = f'/org/freedesktop/portal/desktop/request/{sender}/{token}'

    def response(_bus, _sender, _path, _iface, _signal, params):
        outcome['response'], outcome['results'] = params.unpack()
        loop.quit()
    subscription = bus.signal_subscribe('org.freedesktop.portal.Desktop', 'org.freedesktop.portal.Request', 'Response', handle,
                                        None, Gio.DBusSignalFlags.NO_MATCH_RULE, response)
    bus.call_sync('org.freedesktop.DBus', '/org/freedesktop/DBus', 'org.freedesktop.DBus', 'AddMatch',
                  GLib.Variant('(s)', (f"type='signal',interface='org.freedesktop.portal.Request',path='{handle}'",)), None, Gio.DBusCallFlags.NONE, -1, None)
    options = {**options, 'handle_token': GLib.Variant('s', token)}
    portal_call('org.freedesktop.portal.FileChooser', method, GLib.Variant('(ssa{sv})', ('', 'Bridge check', options)), '(o)')
    GLib.timeout_add_seconds(20, loop.quit)
    loop.run()
    bus.signal_unsubscribe(subscription)
    host.stop = True
    return outcome.get('response'), outcome.get('results', {}), host.seen


def files():
    folder = core.HOME / '.cache/caboose/bridge-check'
    folder.mkdir(parents=True, exist_ok=True)
    picked = folder / 'picked.txt'
    picked.write_text('bridge check\n')
    try:
        response, results, seen = file_chooser('OpenFile', {'filters': GLib.Variant('a(sa(us))', [('Text', [(0, '*.txt'), (1, 'text/plain')])])},
                                               lambda r: {'id': r['id'], 'response': 'ok', 'paths': [str(picked)], 'filter': 0})
        check(len(seen) == 1 and seen[0]['type'] == 'file.open' and seen[0]['filters'][0]['patterns'] == ['*.txt'], 'OpenFile reaches the phone as a file.open request')
        check(response == 0 and results.get('uris') == [Gio.File.new_for_path(str(picked)).get_uri()], 'the phone\'s answer returns the chosen file to the application')
        response, _, _ = file_chooser('SaveFile', {'current_name': GLib.Variant('s', 'new.txt')}, lambda r: {'id': r['id'], 'response': 'cancel'})
        check(response == 1, 'a cancelled save answers response 1')
        response, results, seen = file_chooser('SaveFile', {'current_name': GLib.Variant('s', 'new.txt'), 'current_folder': GLib.Variant('ay', str(folder).encode() + b'\0')},
                                               lambda r: {'id': r['id'], 'response': 'ok', 'paths': [f"{r['currentFolder']}/{r['currentName']}"]})
        check(seen and seen[0]['currentName'] == 'new.txt' and seen[0]['currentFolder'] == str(folder), 'SaveFile carries the suggested name and folder')
        check(response == 0 and results.get('uris') == [Gio.File.new_for_path(str(folder / 'new.txt')).get_uri()], 'the phone\'s save path returns to the application')
    finally:
        for f in folder.iterdir():
            f.unlink()
        folder.rmdir()


PLAYER_XML = '''<node><interface name="org.mpris.MediaPlayer2"><property name="Identity" type="s" access="read"/></interface>
<interface name="org.mpris.MediaPlayer2.Player"><method name="Play"/><method name="Pause"/><method name="PlayPause"/><method name="Next"/><method name="Previous"/>
<method name="SetPosition"><arg type="o" direction="in"/><arg type="x" direction="in"/></method><method name="Seek"><arg type="x" direction="in"/></method>
<property name="PlaybackStatus" type="s" access="read"/><property name="Metadata" type="a{sv}" access="read"/><property name="Position" type="x" access="read"/>
<property name="Rate" type="d" access="read"/><property name="CanPlay" type="b" access="read"/><property name="CanPause" type="b" access="read"/>
<property name="CanGoNext" type="b" access="read"/><property name="CanGoPrevious" type="b" access="read"/><property name="CanSeek" type="b" access="read"/>
<property name="CanControl" type="b" access="read"/></interface></node>'''


def now_playing():
    connection = Gio.DBusConnection.new_for_address_sync(os.environ['DBUS_SESSION_BUS_ADDRESS'],
                                                         Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION, None, None)
    status = {'value': 'Playing'}
    calls = []
    metadata = GLib.Variant('a{sv}', {'mpris:trackid': GLib.Variant('o', '/check/track/1'), 'xesam:title': GLib.Variant('s', 'Bridge check'),
                                      'xesam:artist': GLib.Variant('as', ['Caboose']), 'mpris:length': GLib.Variant('x', 120_000_000)})

    def prop(_c, _s, _p, interface, name):
        values = {'Identity': GLib.Variant('s', 'Check Player'), 'PlaybackStatus': GLib.Variant('s', status['value']), 'Metadata': metadata,
                  'Position': GLib.Variant('x', 5_000_000), 'Rate': GLib.Variant('d', 1.0)}
        return values.get(name, GLib.Variant('b', True))

    def method(_c, _s, _p, _i, name, params, invocation):
        calls.append(name)
        if name == 'Pause':
            status['value'] = 'Paused'
            connection.emit_signal(None, '/org/mpris/MediaPlayer2', 'org.freedesktop.DBus.Properties', 'PropertiesChanged',
                                   GLib.Variant('(sa{sv}as)', ('org.mpris.MediaPlayer2.Player', {'PlaybackStatus': GLib.Variant('s', 'Paused')}, [])))
        invocation.return_value(None)
    for interface in Gio.DBusNodeInfo.new_for_xml(PLAYER_XML).interfaces:
        connection.register_object('/org/mpris/MediaPlayer2', interface, method, prop, None)
    connection.call_sync('org.freedesktop.DBus', '/org/freedesktop/DBus', 'org.freedesktop.DBus', 'RequestName',
                         GLib.Variant('(su)', ('org.mpris.MediaPlayer2.cabooscheck', 4)), None, Gio.DBusCallFlags.NONE, -1, None)
    context = GLib.MainContext.default()

    def wait(predicate, seconds):
        deadline = time.time() + seconds
        while time.time() < deadline:
            while context.pending():
                context.iteration(False)
            if predicate():
                return True
            time.sleep(0.1)
        return False
    shown = lambda: (core.read_json(core.NOW_PLAYING) or {}).get('title') == 'Bridge check'
    check(wait(shown, 10), 'an MPRIS player appears in now-playing.json')
    state = core.read_json(core.NOW_PLAYING) or {}
    check(state.get('player') == 'Check Player' and state.get('duration') == 120 and state.get('paused') is False, 'its identity, duration and status are published')
    core.write_json(core.NOW_PLAYING_COMMAND, {'seq': int(time.time() * 1000), 'id': state.get('id', ''), 'action': 'pause'})
    check(wait(lambda: 'Pause' in calls, 5), 'a pause command reaches the player')
    check(wait(lambda: (core.read_json(core.NOW_PLAYING) or {}).get('paused') is True, 5), 'the paused state is published')
    connection.close_sync(None)
    check(wait(lambda: not core.NOW_PLAYING.exists(), 5), 'now-playing.json is removed when the player goes')


if __name__ == '__main__':
    appearance()
    files()
    now_playing()
    if failures:
        sys.exit(f'{len(failures)} bridge check(s) failed')
    print('The native bridge works on this computer.')
