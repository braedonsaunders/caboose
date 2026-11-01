#!/usr/bin/env python3
"""Unit tests for caboose-ports: socket tables, which ports it forwards, and the HTTP rewrite."""
import asyncio
import os
import importlib.util
import pathlib
import socket
import sys
import unittest

spec = importlib.util.spec_from_file_location('caboose_ports', pathlib.Path(__file__).with_name('caboose-ports.py'))
ports = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ports)

HEADER = '  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n'


def row(local, remote='00000000:0000', state='0A'):
    return f'   0: {local} {remote} {state} 00000000:00000000 00:00000000 00000000  1000        0 1 1 0 100 0 0 10 0\n'


class Tables(unittest.TestCase):
    def test_decodes_addresses(self):
        self.assertEqual(ports.decode_address('0100007F:1435'), ('127.0.0.1', 5173))
        self.assertEqual(ports.decode_address('00000000000000000000000001000000:0BB8'), ('::1', 3000))
        self.assertEqual(ports.decode_address('0000000000000000FFFF00000100007F:1F40'), ('::ffff:127.0.0.1', 8000))

    def test_lists_listeners_only(self):
        tcp = HEADER + row('0100007F:1435') + row('020016AC:1435', '030016AC:C738', '01') + row('00000000:1538')
        tcp6 = HEADER + row('00000000000000000000000001000000:1435')
        self.assertEqual(ports.listeners([tcp, tcp6]), {5173: {'127.0.0.1', '::1'}, 5432: {'0.0.0.0'}})

    def test_skips_malformed_lines(self):
        self.assertEqual(ports.listeners([HEADER + '   0: zz:zz 00:00 0A\n' + 'short\n']), {})


class Forwardable(unittest.TestCase):
    ephemeral = (32768, 60999)

    def test_forwards_loopback_only_ports(self):
        found = {5173: {'::1'}, 8000: {'127.0.0.1', '::1'}, 5432: {'0.0.0.0'}, 3000: {'127.0.0.1', '172.22.0.2'}}
        self.assertEqual(ports.forwardable(found, {}, self.ephemeral), {5173: '::1', 8000: '127.0.0.1'})

    def test_leaves_out_caboose_and_ephemeral_ports(self):
        found = {14600: {'127.0.0.1'}, 14799: {'127.0.0.1'}, 40000: {'127.0.0.1'}, 8888: {'::ffff:127.0.0.1'}}
        self.assertEqual(ports.forwardable(found, {}, self.ephemeral), {8888: '127.0.0.1'})

    def test_its_own_listeners_are_not_the_server(self):
        found = {5173: {'::1', '172.22.0.2'}, 6000: {'172.22.0.2'}}
        self.assertEqual(ports.forwardable(found, {5173: {'172.22.0.2'}, 6000: {'172.22.0.2'}}, self.ephemeral), {5173: '::1'})


class Rewrite(unittest.TestCase):
    def test_rewrites_host_and_matching_origin_and_referer(self):
        head = (b'GET /src/main.js HTTP/1.1\r\nHost: dev-box.tailnet.ts.net:5173\r\nOrigin: http://dev-box.tailnet.ts.net:5173\r\n'
                b'Referer: http://DEV-BOX.tailnet.ts.net:5173/index.html\r\nAccept: */*\r\n\r\n')
        out, framing, upgrade = ports.rewrite_head(head, 5173)
        self.assertEqual(out, b'GET /src/main.js HTTP/1.1\r\nHost: localhost:5173\r\nOrigin: http://localhost:5173\r\n'
                              b'Referer: http://localhost:5173/index.html\r\nAccept: */*\r\n\r\n')
        self.assertEqual((framing, upgrade), (('none',), False))

    def test_keeps_another_site_origin(self):
        out, _, _ = ports.rewrite_head(b'POST / HTTP/1.1\r\nHost: 100.64.1.2:8000\r\nOrigin: https://evil.example\r\nContent-Length: 3\r\n\r\n', 8000)
        self.assertIn(b'Origin: https://evil.example\r\n', out)
        self.assertEqual(ports.rewrite_head(b'POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 3\r\n\r\n', 8000)[1], ('length', 3))

    def test_framing_and_upgrades(self):
        self.assertEqual(ports.rewrite_head(b'POST / HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: chunked\r\nContent-Length: 9\r\n\r\n', 1)[1], ('chunked',))
        self.assertTrue(ports.rewrite_head(b'GET / HTTP/1.1\r\nHost: a\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n', 1)[2])
        with self.assertRaises(ValueError):
            ports.rewrite_head(b'POST / HTTP/1.1\r\nHost: a\r\nContent-Length: -1\r\n\r\n', 1)


def query(name, qtype=1, qclass=1, ident=0, flags=0):
    import struct
    return struct.pack('!HHHHHH', ident, flags, 1, 0, 0, 0) + ports.encode_name(name) + struct.pack('!HH', qtype, qclass)


class Mdns(unittest.TestCase):
    def test_answers_an_a_query_for_its_name_only(self):
        record, unicast, ident, qtype = ports.mdns_answer(query('Dev-Box.local'), 'dev-box.local', '192.168.68.40')
        self.assertEqual(record, ports.encode_name('dev-box.local') + bytes.fromhex('0001 8001 00000078 0004') + bytes([192, 168, 68, 40]))
        self.assertEqual((unicast, ident, qtype), (False, 0, 1))
        self.assertIsNone(ports.mdns_answer(query('other.local'), 'dev-box.local', '192.168.68.40'))
        self.assertIsNone(ports.mdns_answer(query('dev-box.local', qtype=28), 'dev-box.local', '192.168.68.40'))
        self.assertIsNone(ports.mdns_answer(query('dev-box.local', flags=0x8400), 'dev-box.local', '192.168.68.40'))

    def test_honours_the_unicast_bit_and_any(self):
        _, unicast, ident, qtype = ports.mdns_answer(query('dev-box.local', qtype=255, qclass=0x8001, ident=7), 'dev-box.local', '10.0.0.5')
        self.assertEqual((unicast, ident, qtype), (True, 7, 255))

    def test_follows_compression_and_refuses_loops(self):
        packet = query('dev-box.local')
        self.assertEqual(ports.read_name(packet + b'\xc0\x0c', len(packet)), ('dev-box.local', len(packet) + 2))
        with self.assertRaises(ValueError):
            ports.read_name(b'\0' * 12 + b'\xc0\x0c', 12)


class Settings(unittest.TestCase):
    def read(self, text):
        import tempfile
        with tempfile.NamedTemporaryFile('w', suffix='.json', delete=False) as file:
            file.write(text)
        ports.CONFIG = file.name
        try:
            return ports.settings()
        finally:
            os.unlink(file.name)

    def test_reads_the_hosts_switch(self):
        self.assertEqual(self.read('{"forward": true, "mdns": "dev-box"}'), (True, 'dev-box'))
        self.assertEqual(self.read('{"forward": "yes", "mdns": "Not A Label"}'), (False, None))
        self.assertEqual(self.read('[]'), (False, None))
        self.assertEqual(self.read('{'), (False, None))


class Piping(unittest.IsolatedAsyncioTestCase):
    """A real loopback server behind the forwarder's connection handler."""

    async def start(self, respond):
        self.received = bytearray()

        async def server(reader, writer):
            await respond(reader, writer, self.received)
            writer.close()

        self.upstream = await asyncio.start_server(server, '127.0.0.1', 0)
        port = self.upstream.sockets[0].getsockname()[1]
        forwarder = ports.Forwarder()
        forwarder.targets[port] = '127.0.0.1'
        front = await asyncio.start_server(lambda r, w: forwarder.handle(port, r, w), '127.0.0.1', 0)
        self.servers = [self.upstream, front]
        return port, front.sockets[0].getsockname()[1]

    async def asyncTearDown(self):
        for server in getattr(self, 'servers', []):
            server.close()
            await server.wait_closed()

    async def test_rewrites_each_request_on_a_kept_alive_connection_and_bodies_pass_through(self):
        async def respond(reader, writer, received):
            while data := await reader.read(65536):
                received.extend(data)
                if b'GET /c ' in received and received.endswith(b'\r\n\r\n'):
                    break
            writer.write(b'HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok')
            await writer.drain()
        port, front = await self.start(respond)
        reader, writer = await asyncio.open_connection('127.0.0.1', front)
        writer.write(b'POST /a HTTP/1.1\r\nHost: box:1\r\nTransfer-Encoding: chunked\r\n\r\n4\r\nHost\r\n0\r\n\r\n')
        writer.write(b'PUT /b HTTP/1.1\r\nHost: box:1\r\nContent-Length: 11\r\n\r\nHost: x\r\n\r\n')
        writer.write(b'GET /c HTTP/1.1\r\nHost: box:1\r\n\r\n')
        await writer.drain()
        self.assertEqual(await reader.read(), b'HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok')
        writer.close()
        host = f'Host: localhost:{port}'.encode()
        self.assertEqual(bytes(self.received),
                         b'POST /a HTTP/1.1\r\n' + host + b'\r\nTransfer-Encoding: chunked\r\n\r\n4\r\nHost\r\n0\r\n\r\n'
                         + b'PUT /b HTTP/1.1\r\n' + host + b'\r\nContent-Length: 11\r\n\r\nHost: x\r\n\r\n'
                         + b'GET /c HTTP/1.1\r\n' + host + b'\r\n\r\n')

    async def test_pipes_other_protocols_untouched(self):
        async def respond(reader, writer, received):
            received.extend(await reader.readexactly(8))
            writer.write(b'N')
            await writer.drain()
        _, front = await self.start(respond)
        reader, writer = await asyncio.open_connection('127.0.0.1', front)
        startup = b'\x00\x00\x00\x08\x04\xd2\x16\x2f'  # PostgreSQL's SSLRequest
        writer.write(startup)
        await writer.drain()
        self.assertEqual(await reader.read(), b'N')
        self.assertEqual(bytes(self.received), startup)
        writer.close()

    async def test_switches_to_raw_bytes_after_an_upgrade(self):
        async def respond(reader, writer, received):
            received.extend(await reader.readuntil(b'\r\n\r\n'))
            writer.write(b'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n')
            await writer.drain()
            received.extend(await reader.readexactly(14))
        port, front = await self.start(respond)
        reader, writer = await asyncio.open_connection('127.0.0.1', front)
        writer.write(b'GET /hmr HTTP/1.1\r\nHost: box:5173\r\nOrigin: http://box:5173\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n')
        await writer.drain()
        await reader.readuntil(b'\r\n\r\n')
        writer.write(b'GET / HTTP/1.1')  # Frame bytes that look like HTTP must not be rewritten.
        await writer.drain()
        await asyncio.sleep(0.05)
        writer.close()
        await asyncio.sleep(0.05)
        self.assertIn(f'Origin: http://localhost:{port}'.encode(), bytes(self.received))
        self.assertTrue(bytes(self.received).endswith(b'\r\n\r\nGET / HTTP/1.1'))

    async def test_refuses_a_port_no_longer_forwarded(self):
        forwarder = ports.Forwarder()
        front = await asyncio.start_server(lambda r, w: forwarder.handle(5173, r, w), '127.0.0.1', 0)
        reader, writer = await asyncio.open_connection('127.0.0.1', front.sockets[0].getsockname()[1])
        self.assertEqual(await reader.read(), b'')
        writer.close()
        self.servers = [front]


class Following(unittest.IsolatedAsyncioTestCase):
    """step() against a stand-in /proc/net and address list: forwards appear, follow new addresses, and stop."""

    async def test_follows_the_servers_and_the_computers_addresses(self):
        import tempfile
        proc = tempfile.mkdtemp()
        config = os.path.join(proc, 'ports.json')
        with open(config, 'w') as file:
            file.write('{"forward": true}')
        probe = socket.socket()
        probe.bind(('127.0.0.1', 0))
        port = probe.getsockname()[1]
        probe.close()
        tables = lambda listening: open(os.path.join(proc, 'tcp'), 'w').write(HEADER + (row(f'0100007F:{port:04X}') if listening else ''))
        saved = (ports.PROC_NET, ports.CONFIG, ports.external_addresses, ports.ephemeral_range)
        addresses = {'127.0.0.2'} if sys.platform == 'linux' else set()
        ports.PROC_NET, ports.CONFIG, ports.ephemeral_range = proc, config, lambda: (60000, 60001)
        ports.external_addresses = lambda: set(addresses)
        forwarder = ports.Forwarder()
        try:
            tables(True)
            await forwarder.step()
            self.assertEqual(forwarder.targets, {port: '127.0.0.1'})
            self.assertEqual(set(forwarder.servers.get(port, {})), addresses)
            if sys.platform == 'linux':
                addresses.add('127.0.0.3')
                await forwarder.step()
                self.assertEqual(set(forwarder.servers[port]), {'127.0.0.2', '127.0.0.3'})
                addresses.discard('127.0.0.2')
                await forwarder.step()
                self.assertEqual(set(forwarder.servers[port]), {'127.0.0.3'})
            tables(False)
            await forwarder.step()
            self.assertEqual((forwarder.servers, forwarder.targets), ({}, {}))
        finally:
            ports.PROC_NET, ports.CONFIG, ports.external_addresses, ports.ephemeral_range = saved
            for servers in forwarder.servers.values():
                for server in servers.values():
                    server.close()


if __name__ == '__main__':
    unittest.main()
