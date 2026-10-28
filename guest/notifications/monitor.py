#!/usr/bin/python3
"""Observe owner-seat desktop notification calls and spool bounded, private records."""
import json
import os
import pathlib
import time
import uuid
from gi.repository import Gio, GLib

BUS = os.environ.get('DBUS_SESSION_BUS_ADDRESS', 'unix:path=/run/user/1000/bus')
QUEUE = pathlib.Path('/home/caboose/.cache/caboose/notifications')
FLAGS = Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION
monitor = Gio.DBusConnection.new_for_address_sync(BUS, FLAGS, None, None)
QUEUE.mkdir(mode=0o700, parents=True, exist_ok=True)

def process(args):
    try:
        if len(args) != 8:
            return False
        app, _, _, summary, body, _, _, _ = args
        record = {'id': str(uuid.uuid4()), 'app': str(app)[:200], 'summary': str(summary)[:500], 'body': str(body)[:1000], 'created': int(time.time())}
        temporary = QUEUE / ('.' + record['id'])
        with temporary.open('x', encoding='utf-8') as file:
            os.chmod(temporary, 0o600)
            json.dump(record, file, ensure_ascii=True)
        temporary.rename(QUEUE / (record['id'] + '.json'))
        # The host can drain concurrently; a disappearing file must not discard this event.
        entries = []
        for path in QUEUE.glob('*.json'):
            try:
                entries.append((path.stat().st_mtime_ns, path))
            except FileNotFoundError:
                pass
        for _, path in sorted(entries)[:-100]:
            path.unlink(missing_ok=True)
    except (OSError, ValueError, TypeError, GLib.Error) as error:
        print('notification monitor:', error, flush=True)
    return False

def receive(_connection, message, incoming, _data):
    if not incoming or message.get_message_type() != Gio.DBusMessageType.METHOD_CALL:
        return message
    # Monitors must never reply to observed calls; stop GDBus dispatching them.
    if message.get_interface() == 'org.freedesktop.Notifications' and message.get_member() == 'Notify':
        # Filters run on GDBus's I/O thread: write the queue on the main loop.
        GLib.idle_add(process, message.get_body().unpack())
    return None

monitor.add_filter(receive, None)
monitor.call_sync('org.freedesktop.DBus', '/org/freedesktop/DBus', 'org.freedesktop.DBus.Monitoring', 'BecomeMonitor', GLib.Variant('(asu)', (["type='method_call',interface='org.freedesktop.Notifications',member='Notify'"], 0)), None, Gio.DBusCallFlags.NONE, 5000, None)
GLib.MainLoop().run()
