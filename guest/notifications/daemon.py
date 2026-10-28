#!/usr/bin/python3
"""Notification endpoint for Caboose Display, where Xpra is not the D-Bus server."""
from gi.repository import Gio, GLib
xml = '''<node><interface name="org.freedesktop.Notifications">
<method name="GetServerInformation"><arg type="s" direction="out"/><arg type="s" direction="out"/><arg type="s" direction="out"/><arg type="s" direction="out"/></method>
<method name="GetCapabilities"><arg type="as" direction="out"/></method>
<method name="Notify"><arg type="s" direction="in"/><arg type="u" direction="in"/><arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="as" direction="in"/><arg type="a{sv}" direction="in"/><arg type="i" direction="in"/><arg type="u" direction="out"/></method>
<method name="CloseNotification"><arg type="u" direction="in"/></method>
</interface></node>'''
loop = GLib.MainLoop()
next_id = 0
def called(_connection, _sender, _path, _interface, method, parameters, invocation):
    global next_id
    if method == 'GetServerInformation':
        invocation.return_value(GLib.Variant('(ssss)', ('Caboose', 'Caboose', '1', '1.2')))
    elif method == 'GetCapabilities':
        invocation.return_value(GLib.Variant('(as)', ([],)))
    elif method == 'CloseNotification':
        invocation.return_value(GLib.Variant('()', ()))
    else:
        replacement = parameters.unpack()[1]
        next_id = (next_id % 0xfffffffe) + 1
        invocation.return_value(GLib.Variant('(u)', (replacement or next_id,)))
def acquired(connection, _name):
    connection.register_object('/org/freedesktop/Notifications', Gio.DBusNodeInfo.new_for_xml(xml).interfaces[0], called, None, None)
def lost(_connection, _name):
    loop.quit()
Gio.bus_own_name(Gio.BusType.SESSION, 'org.freedesktop.Notifications', Gio.BusNameOwnerFlags.NONE, acquired, None, lost)
loop.run()
