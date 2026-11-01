#!/usr/bin/env python3
"""Loopback servers on the computer's own address, as on a developer's desktop.

Vite, Django, Rails, Jupyter and PostgreSQL listen on 127.0.0.1 or ::1 by default, which no
other machine can reach. While the host says the computer has an address of its own
(/run/caboose/ports.json), this service watches the kernel's listening sockets and, for every
TCP port that only a loopback address listens on, listens on the same port of each of the
computer's other IPv4 addresses and pipes each connection to the loopback server. An HTTP
request's Host, Origin and Referer are rewritten to http://localhost:<port>, so a dev server's
own DNS-rebinding and CSRF checks see the request they expect. On a computer with an address
on the home network (lan0) it also answers mDNS for <name>.local. See docs/network.md.
"""
import asyncio
import fcntl
import json
import os
import re
import socket
import struct
import sys
import time

CONFIG = os.environ.get('CABOOSE_PORTS_CONFIG', '/run/caboose/ports.json')
PROC_NET = os.environ.get('CABOOSE_PORTS_PROC', '/proc/net')
POLL_SECONDS = 0.5
# A port another program holds on the external address is tried again this often.
RETRY_SECONDS = 30
# Caboose's own services (display, agent seat, files, terminal): only the host reaches them.
CABOOSE_PORTS = range(14600, 14800)
HEAD_LIMIT = 64 * 1024
BUFFER = 64 * 1024
SIOCGIFADDR = 0x8915


def decode_address(field):
    """A /proc/net address: 8 or 32 hex digits, each 32-bit word little-endian, then the port."""
    host, _, port = field.partition(':')
    raw = bytes.fromhex(host)
    raw = b''.join(raw[i:i + 4][::-1] for i in range(0, len(raw), 4))
    family = socket.AF_INET if len(raw) == 4 else socket.AF_INET6
    return socket.inet_ntop(family, raw), int(port, 16)


def is_loopback(address):
    if address.startswith('::ffff:'):
        address = address[7:]
    return address.startswith('127.') or address == '::1'


def listeners(tables):
    """{port: set of listening addresses} from the text of /proc/net/tcp and tcp6."""
    found = {}
    for text in tables:
        for line in text.splitlines()[1:]:
            fields = line.split()
            if len(fields) < 4 or fields[3] != '0A':
                continue
            try:
                address, port = decode_address(fields[1])
            except ValueError:
                continue
            found.setdefault(port, set()).add(address)
    return found


def forwardable(found, ours, ephemeral):
    """Ports only loopback listens on, leaving out Caboose's own and the ephemeral range.

    Each port maps to the loopback address to dial: IPv4 when it listens there, else ::1.
    `ours` is {port: addresses} of this service's own listeners, which are not the server's.
    """
    result = {}
    for port, addresses in found.items():
        if port in CABOOSE_PORTS or ephemeral[0] <= port <= ephemeral[1]:
            continue
        server = addresses - ours.get(port, set())
        if server and all(is_loopback(address) for address in server):
            result[port] = '127.0.0.1' if any(not address.startswith('::') or address.startswith('::ffff:') for address in server) else '::1'
    return result


def interface_address(name):
    """An interface's IPv4 address, or None."""
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as probe:
        try:
            packed = fcntl.ioctl(probe.fileno(), SIOCGIFADDR, struct.pack('256s', name.encode()[:15]))
        except OSError:
            return None
    return socket.inet_ntoa(packed[20:24])


def external_addresses():
    """The computer's IPv4 addresses on every interface but loopback."""
    return {address for _, name in socket.if_nameindex() if name != 'lo' and (address := interface_address(name))}


def ephemeral_range():
    try:
        with open('/proc/sys/net/ipv4/ip_local_port_range') as file:
            low, high = file.read().split()
        return int(low), int(high)
    except (OSError, ValueError):
        return 32768, 60999


def settings():
    """The host's switch: {"forward": bool, "mdns": name on the home network, if it has one}."""
    try:
        with open(CONFIG) as file:
            value = json.load(file)
    except (OSError, ValueError):
        return False, None
    if not isinstance(value, dict):
        return False, None
    name = value.get('mdns')
    return value.get('forward') is True, name if isinstance(name, str) and MDNS_LABEL.match(name) else None


MDNS_GROUP, MDNS_PORT = '224.0.0.251', 5353
MDNS_LABEL = re.compile(r'^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$')
LAN_INTERFACE = 'lan0'


def read_name(packet, offset):
    """A DNS name at offset, following compression pointers; returns (name, offset after it)."""
    labels, end, jumps = [], None, 0
    while True:
        length = packet[offset]
        if length & 0xC0 == 0xC0:
            if jumps > 16:
                raise ValueError('pointer loop')
            if end is None:
                end = offset + 2
            offset, jumps = ((length & 0x3F) << 8) | packet[offset + 1], jumps + 1
            continue
        offset += 1
        if length == 0:
            return '.'.join(labels), end if end is not None else offset
        labels.append(packet[offset:offset + length].decode('ascii', 'replace'))
        offset += length


def encode_name(name):
    return b''.join(bytes([len(label)]) + label.encode() for label in name.split('.')) + b'\0'


def mdns_answer(packet, name, address):
    """The response to an mDNS query for name's A record (or ANY), or None.

    Returns (record, unicast, query ID, question type): unicast when the query asked for it
    (the QU bit). A query from a port other than 5353 (a one-shot resolver) is answered to its
    sender with its ID and question.
    """
    if len(packet) < 12:
        return None
    ident, flags, questions = struct.unpack('!HHH', packet[:6])
    if flags & 0x8000:
        return None
    offset, wanted = 12, name.lower()
    for _ in range(questions):
        qname, offset = read_name(packet, offset)
        qtype, qclass = struct.unpack('!HH', packet[offset:offset + 4])
        offset += 4
        if qname.lower() == wanted and qtype in (1, 255) and qclass & 0x7FFF in (1, 255):
            record = encode_name(name) + struct.pack('!HHIH', 1, 0x8001, 120, 4) + socket.inet_aton(address)
            return record, bool(qclass & 0x8000), ident, qtype
    return None


class Responder(asyncio.DatagramProtocol):
    """Answers for <name>.local on the home network, so phones there find the computer by name."""

    def __init__(self, name, address):
        self.name, self.address, self.transport = f'{name}.local', address, None

    def connection_made(self, transport):
        self.transport = transport
        self.announce()

    def announce(self):
        record = encode_name(self.name) + struct.pack('!HHIH', 1, 0x8001, 120, 4) + socket.inet_aton(self.address)
        self.transport.sendto(struct.pack('!HHHHHH', 0, 0x8400, 0, 1, 0, 0) + record, (MDNS_GROUP, MDNS_PORT))

    def datagram_received(self, data, sender):
        try:
            answer = mdns_answer(data, self.name, self.address)
        except (ValueError, IndexError, struct.error):
            return
        if not answer:
            return
        record, unicast, ident, qtype = answer
        if sender[1] != MDNS_PORT:
            question = encode_name(self.name) + struct.pack('!HH', qtype, 1)
            self.transport.sendto(struct.pack('!HHHHHH', ident, 0x8400, 1, 1, 0, 0) + question + record, sender)
        else:
            self.transport.sendto(struct.pack('!HHHHHH', 0, 0x8400, 0, 1, 0, 0) + record, sender if unicast else (MDNS_GROUP, MDNS_PORT))


def mdns_socket(address):
    """UDP 5353 shared with any other responder in the computer, joined to the group on lan0."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    if hasattr(socket, 'SO_REUSEPORT'):
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
    sock.bind(('0.0.0.0', MDNS_PORT))
    sock.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, socket.inet_aton(MDNS_GROUP) + socket.inet_aton(address))
    sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_IF, socket.inet_aton(address))
    sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 255)
    sock.setblocking(False)
    return sock


METHOD = re.compile(rb'^[A-Z]{3,10} [^\s]')


def rewrite_head(head, port):
    """One HTTP/1.x request head with Host, Origin and Referer naming http://localhost:<port>.

    Origin and Referer change only when they name the host the client used. Returns the new
    head, the body's framing ('length', n), ('chunked',) or ('none',), and whether the
    connection becomes raw bytes afterwards (an Upgrade or CONNECT).
    """
    lines = head.split(b'\r\n')
    request, headers = lines[0], [line for line in lines[1:] if line]
    local = f'localhost:{port}'.encode()
    original = next((line.split(b':', 1)[1].strip() for line in headers if line.lower().startswith(b'host:')), None)
    framing, upgrade = ('none',), request.startswith(b'CONNECT ')
    out = [request]
    for line in headers:
        name, _, value = line.partition(b':')
        key, value = name.strip().lower(), value.strip()
        if key == b'host':
            line = b'Host: ' + local
        elif key in (b'origin', b'referer') and original:
            match = re.match(rb'^(https?)://([^/]+)(.*)$', value)
            if match and match.group(2).lower() == original.lower():
                line = name + b': http://' + local + match.group(3)
        elif key == b'content-length' and framing[0] != 'chunked':
            if not value.isdigit():
                raise ValueError('bad Content-Length')
            framing = ('length', int(value))
        elif key == b'transfer-encoding' and value.lower().split(b',')[-1].strip() == b'chunked':
            framing = ('chunked',)
        elif key == b'upgrade':
            upgrade = True
        out.append(line)
    return b'\r\n'.join(out) + b'\r\n\r\n', framing, upgrade


async def copy(reader, writer):
    try:
        while data := await reader.read(BUFFER):
            writer.write(data)
            await writer.drain()
    except (ConnectionError, OSError):
        pass
    finally:
        try:
            if writer.can_write_eof():
                writer.write_eof()
        except (OSError, RuntimeError):
            pass


async def copy_exactly(reader, writer, count):
    while count:
        data = await reader.read(min(count, BUFFER))
        if not data:
            raise ConnectionError('closed inside a body')
        writer.write(data)
        await writer.drain()
        count -= len(data)


async def copy_chunked(reader, writer):
    while True:
        size_line = await reader.readuntil(b'\r\n')
        writer.write(size_line)
        size = int(size_line.split(b';', 1)[0].strip() or b'0', 16)
        if size == 0:
            while (trailer := await reader.readuntil(b'\r\n')) != b'\r\n':
                writer.write(trailer)
            writer.write(b'\r\n')
            await writer.drain()
            return
        await copy_exactly(reader, writer, size + 2)


async def requests(reader, writer, port):
    """Client to server: HTTP requests rewritten one by one; anything else as raw bytes."""
    stream = Prefixed(b'', reader)
    try:
        while True:
            start = await stream.peek()
            if not start:
                return
            if not METHOD.match(start):
                # Not HTTP (TLS, PostgreSQL, a protocol after an upgrade): bytes as they come.
                await stream.drain_into(writer)
                return await copy(reader, writer)
            try:
                head = await stream.readuntil(b'\r\n\r\n')
            except asyncio.LimitOverrunError:
                await stream.drain_into(writer)
                return await copy(reader, writer)
            head, framing, upgrade = rewrite_head(head, port)
            writer.write(head)
            if upgrade:
                await stream.drain_into(writer)
                return await copy(reader, writer)
            if framing[0] == 'length':
                await copy_exactly(stream, writer, framing[1])
            elif framing[0] == 'chunked':
                await copy_chunked(stream, writer)
            await writer.drain()
    except (ConnectionError, OSError, ValueError, asyncio.IncompleteReadError):
        pass
    finally:
        try:
            if writer.can_write_eof():
                writer.write_eof()
        except (OSError, RuntimeError):
            pass


class Prefixed:
    """A stream reader that returns `prefix` before reading on from `reader`."""

    def __init__(self, prefix, reader):
        self.prefix, self.reader = prefix, reader

    async def peek(self):
        """What comes next, reading once if nothing is buffered; empty at the end."""
        if not self.prefix:
            self.prefix = await self.reader.read(BUFFER)
        return self.prefix

    async def read(self, count):
        if self.prefix:
            data, self.prefix = self.prefix[:count], self.prefix[count:]
            return data
        return await self.reader.read(count)

    async def readuntil(self, separator):
        while separator not in self.prefix:
            if len(self.prefix) > HEAD_LIMIT:
                raise asyncio.LimitOverrunError('line too long', len(self.prefix))
            data = await self.reader.read(BUFFER)
            if not data:
                raise asyncio.IncompleteReadError(self.prefix, None)
            self.prefix += data
        line, _, self.prefix = self.prefix.partition(separator)
        return line + separator

    async def drain_into(self, writer):
        if self.prefix:
            writer.write(self.prefix)
            self.prefix = b''
        await writer.drain()

class Forwarder:
    def __init__(self):
        self.servers = {}  # port -> {external address: asyncio server}
        self.targets = {}  # port -> loopback address to dial
        self.failed = {}  # (port, address) -> when listening there last failed
        self.mdns, self.mdns_key = None, None

    def own(self):
        return {port: set(servers) for port, servers in self.servers.items()}

    async def handle(self, port, client_reader, client_writer):
        target = self.targets.get(port)
        try:
            if target is None:
                raise ConnectionError('no longer forwarded')
            server_reader, server_writer = await asyncio.wait_for(asyncio.open_connection(target, port), 10)
        except (OSError, asyncio.TimeoutError, ConnectionError):
            client_writer.close()
            return
        try:
            await asyncio.gather(requests(client_reader, server_writer, port), copy(server_reader, client_writer))
        finally:
            for writer in (server_writer, client_writer):
                writer.close()

    async def listen(self, port, address):
        """Listens on one external address for a forwarded port; a failure is retried later."""
        if time.monotonic() - self.failed.get((port, address), -RETRY_SECONDS) < RETRY_SECONDS:
            return
        try:
            server = await asyncio.start_server(lambda r, w, port=port: self.handle(port, r, w), address, port, reuse_address=True)
        except OSError as error:
            self.failed[(port, address)] = time.monotonic()
            print(f'caboose-ports: cannot forward {address}:{port}: {error}', file=sys.stderr, flush=True)
            return
        self.servers.setdefault(port, {})[address] = server
        print(f'caboose-ports: forwarding {address}:{port}', flush=True)

    def close(self, port, address=None):
        servers = self.servers.get(port, {})
        for held in [address] if address else list(servers):
            if held in servers:
                servers.pop(held).close()
        if not servers:
            self.servers.pop(port, None)
            self.targets.pop(port, None)
        print(f'caboose-ports: stopped forwarding {address + ":" if address else ""}{port}', flush=True)

    async def answer(self, name):
        """Keeps the mDNS responder for name on lan0's current address, or stops it."""
        address = interface_address(LAN_INTERFACE) if name else None
        key = (name, address) if address else None
        if key == self.mdns_key:
            return
        if self.mdns:
            self.mdns.close()
            self.mdns = None
        self.mdns_key = key
        if key:
            try:
                self.mdns, _ = await asyncio.get_running_loop().create_datagram_endpoint(lambda: Responder(name, address), sock=mdns_socket(address))
                print(f'caboose-ports: answering for {name}.local at {address}', flush=True)
            except OSError as error:
                print(f'caboose-ports: cannot answer for {name}.local: {error}', file=sys.stderr, flush=True)

    async def step(self):
        wanted = {}
        forward, mdns = settings()
        await self.answer(mdns)
        if forward:
            tables = []
            for name in ('tcp', 'tcp6'):
                try:
                    with open(os.path.join(PROC_NET, name)) as file:
                        tables.append(file.read())
                except OSError:
                    pass
            wanted = forwardable(listeners(tables), self.own(), ephemeral_range())
        addresses = external_addresses() if wanted else set()
        for port in list(self.servers):
            if port not in wanted:
                self.close(port)
        for port in set(self.targets) - set(wanted):
            del self.targets[port]
        for port, target in wanted.items():
            # Addresses come and go (lan0 arrives after a wake): follow them.
            for address in set(self.servers.get(port, {})) - addresses:
                self.close(port, address)
            self.targets[port] = target
            for address in sorted(addresses - set(self.servers.get(port, {}))):
                await self.listen(port, address)

    async def run(self):
        while True:
            try:
                await self.step()
            except Exception as error:  # Keep serving: one bad poll never ends forwarding.
                print(f'caboose-ports: {error}', file=sys.stderr, flush=True)
            await asyncio.sleep(POLL_SECONDS)


if __name__ == '__main__':
    asyncio.run(Forwarder().run())
