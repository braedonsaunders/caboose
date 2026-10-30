#!/usr/bin/python3
"""Route only Secret Service from the agent bus, preserving per-client sessions."""
import os
import sys
import threading
from pathlib import Path
from gi.repository import Gio, GLib

SERVICE = 'org.freedesktop.secrets'
ROOT = '/org/freedesktop/secrets'
DBUS = 'org.freedesktop.DBus'


def connect(address):
    bus = Gio.DBusConnection.new_for_address_sync(address,
        Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION, None, None)
    bus.set_exit_on_close(False)
    return bus


def bus_call(bus, method, signature, args):
    return bus.call_sync(DBUS, '/org/freedesktop/DBus', DBUS, method,
                         GLib.Variant(signature, args), None, Gio.DBusCallFlags.NONE, 5000, None).unpack()


class Forwarder:
    def __init__(self, agent, owner_address):
        self.agent, self.owner_address = agent, owner_address
        self.clients = {}
        self.admitted = 0
        self.admission_lock = threading.Lock()
        agent.connect('closed', lambda connection, vanished, error: os._exit(1) if vanished else None)
        agent.add_filter(self.filter, None)
        agent.signal_subscribe(DBUS, DBUS, 'NameOwnerChanged', '/org/freedesktop/DBus', None,
                               Gio.DBusSignalFlags.NONE, self.disconnected, None)
        if bus_call(agent, 'RequestName', '(su)', (SERVICE, 4))[0] != 1:
            raise RuntimeError('Secret Service already owned')

    def disconnected(self, bus, sender, path, interface, signal, args, data):
        name, old, new = args.unpack()
        if name.startswith(':') and not new:
            upstream = self.clients.pop(name, None)
            if upstream:
                upstream.close_sync(None)

    def release(self):
        with self.admission_lock:
            self.admitted -= 1

    def filter(self, bus, message, incoming, data):
        if incoming and message.get_message_type() == Gio.DBusMessageType.METHOD_CALL:
            # Gio filters execute on the I/O thread. Bound queued callbacks as well
            # as upstream calls before allocating a copy or scheduling main-loop work.
            with self.admission_lock:
                accepted = self.admitted < 128
                if accepted:
                    self.admitted += 1
            if not accepted:
                self.error(message, 'org.freedesktop.DBus.Error.LimitsExceeded', 'Credential request limit')
                return None
            try:
                GLib.idle_add(self.forward, message.copy())
            except Exception:
                self.release()
                self.error(message, 'org.freedesktop.DBus.Error.Failed', 'Credential dispatch unavailable')
            return None
        return message

    def error(self, request, name, text):
        self.agent.send_message(request.new_method_error_literal(name, text), Gio.DBusSendMessageFlags.NONE)

    def upstream(self, sender):
        if sender not in self.clients:
            if len(self.clients) >= 64:
                raise RuntimeError('client limit')
            # The bus authenticates EXTERNAL credentials. Each agent sender gets a
            # separate upstream identity: session objects are scoped to that identity.
            if bus_call(self.agent, 'GetConnectionUnixUser', '(s)', (sender,))[0] != os.getuid():
                raise RuntimeError('wrong uid')
            bus = connect(self.owner_address)
            try:
                try:
                    owner = bus_call(bus, 'GetNameOwner', '(s)', (SERVICE,))[0]
                except GLib.Error as error:
                    if not Gio.DBusError.is_remote_error(error) or Gio.DBusError.get_remote_error(error) != 'org.freedesktop.DBus.Error.NameHasNoOwner':
                        raise
                    bus_call(bus, 'StartServiceByName', '(su)', (SERVICE, 0))
                    owner = bus_call(bus, 'GetNameOwner', '(s)', (SERVICE,))[0]
                if bus_call(bus, 'GetConnectionUnixUser', '(s)', (owner,))[0] != os.getuid():
                    raise RuntimeError('wrong service uid')
                bus.secret_owner = owner
                bus.signal_subscribe(SERVICE, None, None, None, None, Gio.DBusSignalFlags.NONE,
                                     self.signal, sender)
                # Any backend restart invalidates cryptographic sessions. Fail closed;
                # D-Bus activation starts a fresh forwarder for subsequent clients.
                bus.signal_subscribe(DBUS, DBUS, 'NameOwnerChanged', '/org/freedesktop/DBus', SERVICE,
                                     Gio.DBusSignalFlags.NONE, self.backend_changed, None)
                bus.connect('closed', lambda connection, vanished, error: os._exit(1) if vanished else None)
            except Exception:
                bus.close_sync(None)
                raise
            self.clients[sender] = bus
        return self.clients[sender]

    def backend_changed(self, bus, sender, path, interface, signal, args, data):
        os._exit(1)

    def signal(self, bus, sender, path, interface, member, args, client):
        if (path == ROOT or path.startswith(ROOT + '/')) and (interface.startswith('org.freedesktop.Secret.') or interface == 'org.freedesktop.DBus.Properties'):
            # Unicast, including backend broadcast changes; never expose another
            # client's directed signals. Prompt execution is refused below.
            self.agent.emit_signal(client, path, interface, member, args)

    def forward(self, request):
        scheduled = False
        try:
            path, interface = request.get_path() or '', request.get_interface() or ''
            if not (path == ROOT or path.startswith(ROOT + '/')) or interface not in (
                    'org.freedesktop.Secret.Service', 'org.freedesktop.Secret.Collection',
                    'org.freedesktop.Secret.Item', 'org.freedesktop.Secret.Session',
                    'org.freedesktop.Secret.Prompt', 'org.freedesktop.DBus.Properties',
                    'org.freedesktop.DBus.Introspectable', 'org.freedesktop.DBus.Peer'):
                self.error(request, 'org.freedesktop.DBus.Error.AccessDenied', 'Only Secret Service is forwarded')
                return False
            if interface == 'org.freedesktop.Secret.Prompt' and request.get_member() == 'Prompt':
                self.error(request, 'org.caboose.Secret.Error.InteractionRequired',
                           'Unlock or approve the credential operation on the owner seat, then retry')
                return False
            try:
                bus = self.upstream(request.get_sender())
                forwarded = Gio.DBusMessage.new_method_call(bus.secret_owner, path, interface, request.get_member())
                forwarded.set_body(request.get_body())
                bus.send_message_with_reply(forwarded, Gio.DBusSendMessageFlags.NONE, 10000, None,
                                            self.replied, request)
                scheduled = True
            except Exception:
                self.error(request, 'org.freedesktop.DBus.Error.Failed', 'Canonical credential service unavailable')
            return False

        finally:
            if not scheduled:
                self.release()

    def replied(self, bus, result, request):
        try:
            reply = bus.send_message_with_reply_finish(result)
            if reply.get_message_type() == Gio.DBusMessageType.ERROR:
                # Do not relay arbitrary backend diagnostic strings containing data.
                self.error(request, reply.get_error_name(), 'Canonical credential service refused the operation')
            else:
                answer = request.new_method_reply()
                answer.set_body(reply.get_body())
                self.agent.send_message(answer, Gio.DBusSendMessageFlags.NONE)
        except Exception:
            self.error(request, 'org.freedesktop.DBus.Error.Failed', 'Canonical credential service unavailable')

        finally:
            self.release()


def check_agent_bus():
    bus = connect('unix:path=/run/user/1000/agent-bus')
    try:
        pid = bus_call(bus, 'GetConnectionUnixProcessID', '(s)', (DBUS,))[0]
        args = Path(f'/proc/{pid}/cmdline').read_bytes().split(b'\0')
        if b'--config-file=/opt/caboose/keyring/agent-bus.conf' not in args:
            raise RuntimeError('Agent bus needs an explicit restart with the isolated credential configuration')
    finally:
        bus.close_sync(None)


if __name__ == '__main__':
    if sys.argv[1:] == ['--check-bus']:
        try:
            check_agent_bus()
        except Exception:
            print('Agent bus requires an explicit restart with its isolated configuration', file=sys.stderr)
            sys.exit(1)
        sys.exit(0)
    Forwarder(connect(os.environ['DBUS_SESSION_BUS_ADDRESS']), 'unix:path=/run/user/1000/bus')
    GLib.MainLoop().run()
