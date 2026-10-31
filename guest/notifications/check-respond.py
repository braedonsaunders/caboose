#!/usr/bin/python3
"""Run as caboose on a session bus served by `daemon.py --owner`: sends notifications with an
action and an inline reply, checks their queue records, answers them with caboose-notify, and
checks that the application receives ActionInvoked, NotificationReplied and
NotificationClosed. Used by check-container.sh and check.sh."""
import json
import os
import pathlib
import subprocess
import sys
import time

from gi.repository import Gio, GLib

QUEUE = pathlib.Path('/home/caboose/.cache/caboose/notifications')
# The installed command in a computer, else the one beside this check.
NOTIFY = next(path for path in ('/opt/caboose/notifications/caboose-notify', os.path.join(os.path.dirname(os.path.abspath(__file__)), 'caboose-notify')) if os.path.exists(path))
marker = f'caboose-respond-check-{os.getpid()}-{int(time.time())}'
bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
signals = []


def received(_connection, _sender, _path, _interface, signal, parameters, *_data):
    signals.append((signal, parameters.unpack()))


bus.signal_subscribe('org.freedesktop.Notifications', 'org.freedesktop.Notifications', None, '/org/freedesktop/Notifications',
                     None, Gio.DBusSignalFlags.NONE, received)


def fail(message):
    print(message, file=sys.stderr)
    sys.exit(1)


def notify(summary, actions, hints):
    reply = bus.call_sync('org.freedesktop.Notifications', '/org/freedesktop/Notifications', 'org.freedesktop.Notifications', 'Notify',
                          GLib.Variant('(susssasa{sv}i)', ('Check', 0, '', summary, 'body', actions, hints, -1)),
                          GLib.VariantType('(u)'), Gio.DBusCallFlags.NONE, 5000, None)
    return reply.unpack()[0]


def record(summary):
    for _ in range(20):
        for path in QUEUE.glob('*.json'):
            try:
                entry = json.loads(path.read_text())
            except (OSError, ValueError):
                continue
            if entry.get('summary') == summary:
                return entry
        time.sleep(0.25)
    fail(f'{summary} did not reach the queue')


def respond(entry, option):
    output = subprocess.run([sys.executable, NOTIFY, 'respond', entry['id'], option], capture_output=True, text=True, timeout=20, check=True).stdout
    return json.loads(output)['result']


def wait_for(expected):
    context = GLib.MainContext.default()
    deadline = time.monotonic() + 5
    while expected not in signals and time.monotonic() < deadline:
        context.iteration(False) or time.sleep(0.05)
    if expected not in signals:
        fail(f'expected {expected}, received {signals}')


caps = bus.call_sync('org.freedesktop.Notifications', '/org/freedesktop/Notifications', 'org.freedesktop.Notifications', 'GetCapabilities',
                     None, GLib.VariantType('(as)'), Gio.DBusCallFlags.NONE, 5000, None).unpack()[0]
if not {'actions', 'inline-reply'} <= set(caps):
    fail(f'capabilities {caps}')
action_id = notify(marker + '-action', ['default', 'Open', 'read', 'Mark as Read'], {'desktop-entry': GLib.Variant('s', 'org.example.Check.desktop')})
entry = record(marker + '-action')
if entry['actions'] != [{'key': 'read', 'label': 'Mark as Read'}] or entry['defaultAction'] is not True or entry['desktopEntry'] != 'org.example.Check':
    fail(f'action record {entry}')
if respond(entry, '--action=mute') != 'unknown-action':
    fail('an action the notification does not offer was accepted')
if respond(entry, '--action=read') != 'responded':
    fail('the action was not accepted')
wait_for(('ActionInvoked', (action_id, 'read')))
wait_for(('NotificationClosed', (action_id, 2)))
if respond(entry, '--action=read') != 'unknown-notification':
    fail('a closed notification was answered')
reply_id = notify(marker + '-reply', ['inline-reply', 'Reply'], {'x-kde-reply-placeholder-text': GLib.Variant('s', 'Message')})
entry = record(marker + '-reply')
if entry['reply'] != {'label': 'Reply', 'placeholder': 'Message'}:
    fail(f'reply record {entry}')
if respond(entry, '--reply=On my way') != 'responded':
    fail('the reply was not accepted')
wait_for(('NotificationReplied', (reply_id, 'On my way')))
wait_for(('NotificationClosed', (reply_id, 2)))
print('Notification actions and replies reached the application.')
