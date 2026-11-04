"""Bytes from the phone toward guest streams (docs/gpu-live.md, "Toward guest streams")."""
import asyncio
import contextlib
import socket
import unittest
from unittest import mock

from test_live_broker import broker, Writer, Kind, Envelope

EXECUTOR = b'a' * 16


class GuestWriterTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.session = broker.Session(None, EXECUTOR, 1, None, Writer())
        self.session.session_ready.set()
        self.session.bindings.identity = lambda *_args, **_kwargs: (1, (1000, 42, 123))
        self.session.processes[1] = {'ready': asyncio.Event(), 'retired': asyncio.Event(), 'stopping': False,
                                     'streams': set(), 'surfaces': set()}
        self.sequence = 0
        self.peers = []
        self.writers = []

    async def asyncTearDown(self):
        for writer in self.writers:
            writer.transport.abort()
        for peer in self.peers:
            peer.close()
        await asyncio.sleep(0)
        self.session.bindings.finish(self.session.binding_generation)

    async def stream(self, stream_id):
        """A local stream on a real socket: the broker's transport and the process's end."""
        local, peer = socket.socketpair(socket.AF_UNIX, socket.SOCK_STREAM)
        peer.setblocking(False)
        _, writer = await asyncio.open_unix_connection(sock=local)
        reader = broker.LocalSocketReader(writer)
        ready = asyncio.Event(); ready.set()
        self.session.streams[stream_id] = {'process': 1, 'writer': writer, 'reader': reader, 'ready': ready,
                                           'remote_fin': asyncio.Event(), 'local_eof': False, 'discard_reply': False}
        self.session.processes[1]['streams'].add(stream_id)
        self.peers.append(peer)
        self.writers.append(writer)
        return peer

    async def phone(self, kind, stream_id, payload=b''):
        """One phone message, which must be taken without waiting for any process to read."""
        self.sequence += 1
        await asyncio.wait_for(self.session.message(
            Envelope(kind, EXECUTOR, 1, 1, stream_id, self.sequence, payload)), 0.5)

    async def read_all(self, peer, count):
        loop = asyncio.get_running_loop()
        data = bytearray()
        while len(data) < count:
            chunk = await asyncio.wait_for(loop.sock_recv(peer, 1 << 20), 2)
            if not chunk: break
            data.extend(chunk)
        return bytes(data)

    async def test_a_process_that_stops_reading_holds_back_no_other_stream(self):
        stalled = await self.stream(2)
        feed = await self.stream(3)
        # Far past what the local socket holds: every message is still taken at once.
        for index in range(48):
            await self.phone(Kind.DATA, 2, bytes([index]) * 65536)
            await self.phone(Kind.DATA, 3, index.to_bytes(16, 'little'))
        self.assertEqual(await self.read_all(feed, 48 * 16), b''.join(i.to_bytes(16, 'little') for i in range(48)))
        self.assertGreater(self.session.streams[2]['writer'].transport.get_write_buffer_size(), 0)
        self.assertFalse(self.session.failed)
        # The stalled process reads its replies later, every byte in order.
        self.assertEqual(await self.read_all(stalled, 48 * 65536), b''.join(bytes([i]) * 65536 for i in range(48)))

    async def test_end_of_stream_follows_every_byte_queued_before_it(self):
        peer = await self.stream(2)
        for index in range(20):
            await self.phone(Kind.DATA, 2, bytes([index]) * 100000)
        await self.phone(Kind.FIN, 2)
        self.assertTrue(self.session.streams[2]['remote_fin'].is_set())
        data = await self.read_all(peer, 1 << 30)
        self.assertEqual(data, b''.join(bytes([i]) * 100000 for i in range(20)))

    async def test_a_stream_past_its_bound_ends_alone(self):
        stalled = await self.stream(2)
        other = await self.stream(3)
        with mock.patch.object(broker, 'GUEST_STREAM_BYTES', 1 << 20), mock.patch('builtins.print') as output:
            for _ in range(32):
                await self.phone(Kind.DATA, 2, bytes(65536))
                if self.session.streams[2]['discard_reply']: break
            self.assertTrue(self.session.streams[2]['discard_reply'])
            self.assertTrue(self.session.streams[2]['writer'].transport.is_closing())
            self.assertIn('ended unread stream 2 of process 1', output.call_args.args[0])
            # The phone's further bytes for it are discarded until its FIN.
            await self.phone(Kind.DATA, 2, b'late')
            await self.phone(Kind.FIN, 2)
            self.assertTrue(self.session.streams[2]['remote_fin'].is_set())
            await self.phone(Kind.DATA, 3, b'still here')
            self.assertEqual(await self.read_all(other, 10), b'still here')
        self.assertFalse(self.session.failed)
        # The process sees its device stream end: what reached its socket, then end of file.
        received = await self.read_all(stalled, 1 << 30)
        self.assertLessEqual(len(received), 1 << 20)
        self.assertEqual(received, bytes(len(received)))

    async def test_all_streams_together_end_the_one_holding_the_most(self):
        larger = await self.stream(2)
        smaller = await self.stream(3)
        with mock.patch.object(broker, 'GUEST_HELD_BYTES', 2 << 20), mock.patch('builtins.print'):
            for _ in range(20):
                await self.phone(Kind.DATA, 2, bytes(65536))
            for _ in range(32):
                await self.phone(Kind.DATA, 3, bytes(65536))
                if self.session.streams[2]['discard_reply']: break
            self.assertTrue(self.session.streams[2]['discard_reply'])
            self.assertFalse(self.session.streams[3]['discard_reply'])
            held = sum(item['writer'].transport.get_write_buffer_size() for item in self.session.streams.values()
                       if not item['discard_reply'])
            self.assertLessEqual(held, 2 << 20)
        self.assertFalse(self.session.failed)
        del larger, smaller

    async def test_a_stream_its_process_closed_drops_replies_without_ending_the_session(self):
        peer = await self.stream(2)
        peer.close(); self.peers.remove(peer)
        for _ in range(8):
            await self.phone(Kind.DATA, 2, bytes(65536))
            await asyncio.sleep(0)
            if self.session.streams[2]['discard_reply']: break
        self.assertTrue(self.session.streams[2]['discard_reply'])
        await self.phone(Kind.FIN, 2)
        self.assertTrue(self.session.streams[2]['remote_fin'].is_set())
        self.assertFalse(self.session.failed)


if __name__ == '__main__':
    unittest.main()
