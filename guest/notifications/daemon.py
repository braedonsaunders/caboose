#!/usr/bin/python3
"""The org.freedesktop.Notifications endpoint on a seat's session bus: it accepts every
notification so that apps never wait on a missing server.

    daemon.py            the agent seat's endpoint: its notifications go nowhere
    daemon.py --owner    the owner's: it records each notification for the phone, offers
                         actions and inline replies, and answers caboose-notify
"""
import sys
import time

import notifycore as core
from gi.repository import Gio, GLib

if sys.argv[1:] not in ([], ['--owner']):
    sys.exit('usage: daemon.py [--owner]')
OWNER = sys.argv[1:] == ['--owner']
PATH = '/org/freedesktop/Notifications'
INTERFACE = 'org.freedesktop.Notifications'
xml = '''<node><interface name="org.freedesktop.Notifications">
<method name="GetServerInformation"><arg type="s" direction="out"/><arg type="s" direction="out"/><arg type="s" direction="out"/><arg type="s" direction="out"/></method>
<method name="GetCapabilities"><arg type="as" direction="out"/></method>
<method name="Notify"><arg type="s" direction="in"/><arg type="u" direction="in"/><arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="as" direction="in"/><arg type="a{sv}" direction="in"/><arg type="i" direction="in"/><arg type="u" direction="out"/></method>
<method name="CloseNotification"><arg type="u" direction="in"/></method>
<signal name="NotificationClosed"><arg type="u"/><arg type="u"/></signal>
<signal name="ActionInvoked"><arg type="u"/><arg type="s"/></signal>
<signal name="NotificationReplied"><arg type="u"/><arg type="s"/></signal>
</interface></node>'''
# caboose-notify's way in. Only the owner's session bus, which admits only caboose, reaches it.
respond_xml = '''<node><interface name="org.caboose.Notifications">
<method name="Respond"><arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="s" direction="out"/></method>
</interface></node>'''
loop = GLib.MainLoop()
live = core.Live()


def emit(connection, signal, signature, values):
    try:
        connection.emit_signal(None, PATH, INTERFACE, signal, GLib.Variant(signature, values))
    except GLib.Error as error:
        print('notification endpoint:', error, flush=True)


def called(connection, _sender, _path, _interface, method, parameters, invocation):
    if method == 'GetServerInformation':
        invocation.return_value(GLib.Variant('(ssss)', ('Caboose', 'Caboose', '1', '1.2')))
    elif method == 'GetCapabilities':
        invocation.return_value(GLib.Variant('(as)', (list(core.OWNER_CAPABILITIES) if OWNER else [],)))
    elif method == 'CloseNotification':
        number = parameters.unpack()[0]
        invocation.return_value(GLib.Variant('()', ()))
        if live.close(number):
            emit(connection, 'NotificationClosed', '(uu)', (number, core.CLOSED))
    else:
        args = parameters.unpack()
        notice = core.parse(args)
        if notice is None:
            invocation.return_dbus_error('org.freedesktop.DBus.Error.InvalidArgs', 'Malformed notification')
            return
        number, record_id, expired = live.notify(args[1], notice)
        invocation.return_value(GLib.Variant('(u)', (number,)))
        for old in expired:
            emit(connection, 'NotificationClosed', '(uu)', (old, core.EXPIRED))
        if OWNER:
            try:
                core.spool(core.record(notice, record_id, time.time()))
            except (OSError, ValueError, TypeError) as error:
                print('notification endpoint:', error, flush=True)


def respond(connection, _sender, _path, _interface, _method, parameters, invocation):
    record_id, kind, value = parameters.unpack()
    answer = live.respond(record_id, kind, value)
    invocation.return_value(GLib.Variant('(s)', (answer.result,)))
    if answer.result == 'responded':
        emit(connection, answer.signal, '(us)', (answer.id, answer.value))
        if answer.close:
            emit(connection, 'NotificationClosed', '(uu)', (answer.id, core.DISMISSED))


def acquired(connection, _name):
    connection.register_object(PATH, Gio.DBusNodeInfo.new_for_xml(xml).interfaces[0], called, None, None)
    if OWNER:
        connection.register_object('/org/caboose/Notifications', Gio.DBusNodeInfo.new_for_xml(respond_xml).interfaces[0], respond, None, None)


def lost(_connection, _name):
    loop.quit()


if OWNER:
    core.QUEUE.mkdir(mode=0o700, parents=True, exist_ok=True)
Gio.bus_own_name(Gio.BusType.SESSION, 'org.freedesktop.Notifications', Gio.BusNameOwnerFlags.NONE, acquired, None, lost)
loop.run()
