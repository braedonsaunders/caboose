import asyncio
import array
import os
from importlib.machinery import SourceFileLoader
import importlib.util
from pathlib import Path
import sys
import socket
import unittest
from unittest import mock

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / 'broker'))
loader = SourceFileLoader('caboose_live_broker', str(HERE / 'caboose-gpu-broker'))
spec = importlib.util.spec_from_loader(loader.name, loader)
broker = importlib.util.module_from_spec(spec)
loader.exec_module(broker)
from live_protocol import Decoder, Envelope, Kind, encode
from test_gpu_websocket import client_frame
import control_protocol


class Writer:
    def __init__(self): self.data = bytearray(); self.eof = False
    def write(self, data): self.data.extend(data)
    async def drain(self): pass
    def write_eof(self): self.eof = True
    def close(self): pass
    def get_extra_info(self, _name): return object()
    async def wait_closed(self): pass


class LiveBrokerTests(unittest.IsolatedAsyncioTestCase):
    async def test_real_socketpair_websocket_session_roundtrip(self):
        left, right = socket.socketpair()
        left.setblocking(False); right.setblocking(False)
        guest_reader, guest_writer = await asyncio.open_connection(sock=left)
        phone_reader, phone_writer = await asyncio.open_connection(sock=right)
        session = broker.Session(None, b'a' * 16, 1, guest_reader, guest_writer)
        sender = asyncio.create_task(session.send_loop())
        receiver = asyncio.create_task(session.read_loop())
        try:
            session.send(Kind.SESSION, payload=broker.HELLO)
            header = await asyncio.wait_for(phone_reader.readexactly(2), 1)
            self.assertEqual(header, bytes((0x82, 112)))
            body = await asyncio.wait_for(phone_reader.readexactly(112), 1)
            decoded = []; Decoder(b'a' * 16, 1).feed(body, decoded.append)
            self.assertEqual(decoded[0].kind, Kind.SESSION)
            reply = encode(Envelope(Kind.SESSION_READY, b'a' * 16, 1, 0, 0, 1, broker.HELLO))
            phone_writer.write(client_frame(2, reply)); await phone_writer.drain()
            await asyncio.wait_for(session.session_ready.wait(), 1)
        finally:
            sender.cancel(); receiver.cancel()
            await asyncio.gather(sender, receiver, return_exceptions=True)
            guest_writer.close(); phone_writer.close()
            await asyncio.gather(guest_writer.wait_closed(), phone_writer.wait_closed())
            session.bindings.finish(session.binding_generation)

    async def test_session_uses_exact_hello_and_actual_ready(self):
        session = broker.Session(None, b'a' * 16, 1, None, Writer())
        session.send(Kind.SESSION, payload=broker.HELLO)
        frame = session.pending.get_nowait()
        # The WebSocket binary payload must contain the real CGLV session.
        size = frame[1] & 127
        if size == 126: offset = 4
        elif size == 127: offset = 10
        else: offset = 2
        got = []
        decoder = Decoder(b'a' * 16, 1)
        decoder.feed(frame[offset:], got.append)
        self.assertEqual(got[0].kind, Kind.SESSION)
        self.assertEqual(got[0].payload, broker.HELLO)
        await session.message(Envelope(Kind.SESSION_READY, b'a' * 16, 1, 0, 0, 1, broker.HELLO))
        self.assertTrue(session.session_ready.is_set())
        with self.assertRaises(ValueError):
            await session.message(Envelope(Kind.SESSION_READY, b'a' * 16, 1, 0, 0, 2, broker.HELLO))
        session.bindings.finish(session.binding_generation)

    async def test_local_stream_waits_for_real_receipts_and_relays_both_directions(self):
        session = broker.Session(None, b'a' * 16, 1, None, Writer())
        session.session_ready.set()
        class Peer:
            uid, pid, start_ticks = 1000, 42, 123
            def __init__(self): self.open = True
            def alive(self): return self.open
            def close(self): self.open = False
        reader, writer = asyncio.StreamReader(), Writer()
        reader.feed_data(broker.HELLO + b'guest request'); reader.feed_eof()
        decoder = Decoder(b'a' * 16, 1)
        async def next_frame(kind):
            wire = await asyncio.wait_for(session.pending.get(), 1)
            offset = 4 if wire[1] == 126 else 10 if wire[1] == 127 else 2
            got = []; decoder.feed(wire[offset:], got.append)
            self.assertEqual(got[0].kind, kind)
            return got[0]
        with mock.patch.object(broker.PeerIdentity, 'from_socket', return_value=Peer()):
            task = asyncio.create_task(session.local(reader, writer))
            opened = await next_frame(Kind.PROCESS_OPEN)
            self.assertEqual(writer.data, b'')
            await session.message(Envelope(Kind.PROCESS_READY, b'a' * 16, 1, opened.process, 0, 1))
            stream = await next_frame(Kind.STREAM_OPEN)
            self.assertEqual(writer.data, b'')
            await session.message(Envelope(Kind.STREAM_READY, b'a' * 16, 1, opened.process, stream.stream, 2))
            data = await next_frame(Kind.DATA)
            self.assertEqual(data.payload, b'guest request')
            await next_frame(Kind.FIN)
            await session.message(Envelope(Kind.DATA, b'a' * 16, 1, opened.process, stream.stream, 3, b'reply'))
            await session.message(Envelope(Kind.FIN, b'a' * 16, 1, opened.process, stream.stream, 4))
            stopped = await next_frame(Kind.PROCESS_STOP)
            await session.message(Envelope(Kind.PROCESS_RETIRED, b'a' * 16, 1, stopped.process, 0, 5))
            await asyncio.wait_for(task, 1)
        self.assertEqual(writer.data, broker.HELLO + b'reply')
        self.assertTrue(writer.eof)
        self.assertFalse(session.processes)
        session.bindings.finish(session.binding_generation)

    async def test_unsolicited_revocation_cannot_release_lease(self):
        session = broker.Session(None, b'a' * 16, 1, None, Writer())
        session.session_ready.set()
        with self.assertRaises(ValueError):
            await session.message(Envelope(Kind.REVOKED, b'a' * 16, 1, 0, 0, 1))
        self.assertFalse(session.revoked.is_set())
        session.bindings.finish(session.binding_generation)

    async def test_actual_stream_receipts_and_ordered_return_bytes(self):
        session = broker.Session(None, b'a' * 16, 1, None, Writer())
        session.session_ready.set()
        ready, retired, stream_ready, remote_fin = (asyncio.Event() for _ in range(4))
        session.processes[1] = {'ready': ready, 'retired': retired, 'stopping': False, 'streams': {2}}
        writer = Writer()
        session.bindings.identity = lambda _generation, _stream: (1, (1000, 42, 123))
        session.streams[2] = {'process': 1, 'writer': writer, 'ready': stream_ready, 'remote_fin': remote_fin}
        with self.assertRaises(ValueError):
            await session.message(Envelope(Kind.DATA, b'a' * 16, 1, 1, 2, 1, b'early'))
        await session.message(Envelope(Kind.PROCESS_READY, b'a' * 16, 1, 1, 0, 2))
        await session.message(Envelope(Kind.STREAM_READY, b'a' * 16, 1, 1, 2, 3))
        await session.message(Envelope(Kind.DATA, b'a' * 16, 1, 1, 2, 4, b'abc'))
        await session.message(Envelope(Kind.DATA, b'a' * 16, 1, 1, 2, 5, b'def'))
        await session.message(Envelope(Kind.FIN, b'a' * 16, 1, 1, 2, 6))
        self.assertEqual(writer.data, b'abcdef')
        self.assertTrue(writer.eof and remote_fin.is_set())
        with self.assertRaises(ValueError):
            await session.message(Envelope(Kind.DATA, b'a' * 16, 1, 1, 2, 7, b'late'))
        session.bindings.finish(session.binding_generation)

    async def test_revoke_waits_for_matching_native_receipt(self):
        session = broker.Session(None, b'a' * 16, 1, None, Writer())
        session.session_ready.set()
        task = asyncio.create_task(session.revoke())
        await asyncio.sleep(0)
        self.assertFalse(task.done())
        self.assertTrue(session.revoking)
        await session.message(Envelope(Kind.REVOKED, b'a' * 16, 1, 0, 0, 1))
        await asyncio.wait_for(task, 1)
        session.bindings.finish(session.binding_generation)

    async def test_executor_drain_waits_for_native_retirement_and_revocation(self):
        session = broker.Session(None, b'a' * 16, 1, None, Writer())
        session.session_ready.set()
        ready, retired, stream_ready, remote_fin = (asyncio.Event() for _ in range(4))
        ready.set(); stream_ready.set()
        session.processes[1] = {'ready': ready, 'retired': retired, 'stopping': False, 'streams': {2}}
        session.streams[2] = {'process': 1, 'writer': Writer(), 'ready': stream_ready, 'remote_fin': remote_fin}
        session.bindings.identity = lambda _gen, _stream: (1, (1000, 42, 123))
        session.bindings.unbind_stream = mock.Mock()
        session.bindings.retire_process = mock.Mock()
        await session.message(Envelope(Kind.EXECUTOR_DRAIN, b'a' * 16, 1, 0, 0, 1))
        self.assertTrue(session.drain_requested.is_set())
        task = asyncio.create_task(session.drain())
        await asyncio.sleep(0)
        self.assertFalse(task.done())
        self.assertTrue(session.processes[1]['stopping'])
        await session.message(Envelope(Kind.DATA, b'a' * 16, 1, 1, 2, 2, b'drained'))
        await session.message(Envelope(Kind.FIN, b'a' * 16, 1, 1, 2, 3))
        await session.message(Envelope(Kind.PROCESS_RETIRED, b'a' * 16, 1, 1, 0, 4))
        await asyncio.sleep(0)
        self.assertFalse(task.done())
        await session.message(Envelope(Kind.REVOKED, b'a' * 16, 1, 0, 0, 5))
        await asyncio.wait_for(task, 1)
        session.bindings.unbind_stream.assert_called_once_with(session.binding_generation, 2)
        session.bindings.retire_process.assert_called_once_with(session.binding_generation, 1)
        self.assertFalse(session.streams or session.processes)
        session.bindings.finish(session.binding_generation)

    async def test_cancelled_local_writer_is_aborted_before_close_wait(self):
        class HeldWriter(Writer):
            def __init__(self):
                super().__init__()
                self.unblocked = asyncio.Event()
                self.aborted = False
                self.transport = self
            def abort(self):
                self.aborted = True
                self.unblocked.set()
            async def wait_closed(self):
                await self.unblocked.wait()
        class Peer:
            def close(self): pass
        session = broker.Session(None, b'a' * 16, 1, None, Writer())
        reader, writer = asyncio.StreamReader(), HeldWriter()
        with mock.patch.object(broker.PeerIdentity, 'from_socket', return_value=Peer()):
            task = asyncio.create_task(session.local(reader, writer))
            await asyncio.sleep(0)
            session.draining = True
            task.cancel()
            await asyncio.wait_for(asyncio.gather(task, return_exceptions=True), 1)
        self.assertTrue(writer.aborted)
        self.assertFalse(session.failed)
        session.bindings.finish(session.binding_generation)

    async def test_remote_writer_timeout_aborts_without_claiming_cleanup(self):
        class HeldRemote(Writer):
            def __init__(self):
                super().__init__(); self.transport = self; self.aborted = False
            def abort(self): self.aborted = True
            async def wait_closed(self): await asyncio.Event().wait()
        writer = HeldRemote()
        result = await broker.close_owned_writer(writer, abort=False, timeout=0.01)
        self.assertFalse(result)
        self.assertTrue(writer.aborted)

    async def test_failed_remote_writer_is_aborted_before_wait(self):
        class FailedRemote(Writer):
            def __init__(self):
                super().__init__(); self.transport = self; self.unblocked = asyncio.Event(); self.aborted = False
            def abort(self): self.aborted = True; self.unblocked.set()
            async def wait_closed(self): await self.unblocked.wait()
        writer = FailedRemote()
        self.assertTrue(await broker.close_owned_writer(writer, abort=True, timeout=0.1))
        self.assertTrue(writer.aborted)

    @unittest.skipUnless(sys.platform == 'linux', 'Linux AF_UNIX SOCK_SEQPACKET')
    async def test_bind_request_sends_held_fd_and_checks_epoch(self):
        control, peer = socket.socketpair(type=socket.SOCK_SEQPACKET)
        control.setblocking(False); peer.setblocking(False)
        broker_instance = broker.Broker.__new__(broker.Broker)
        broker_instance.control = control
        broker_instance.next_bind = 0
        broker_instance.pending_binds = {}
        broker_instance.bind_send_lock = asyncio.Lock()
        class Bindings:
            def duplicate_process_identity(self, generation, process):
                return (1000, 42, 123), os.open('/dev/null', os.O_RDONLY)
        session = mock.Mock()
        session.draining = False
        session.binding_generation = 1
        session.bindings = Bindings()
        ready = asyncio.Event(); ready.set()
        session.processes = {3: {'ready': ready}}
        broker_instance.session = session
        task = asyncio.create_task(broker_instance.request_bind(session, 3, 17, b'e' * 16))
        try:
            await asyncio.sleep(0)
            data, ancillary, flags, _ = peer.recvmsg(80, socket.CMSG_SPACE(array.array('i').itemsize))
            record = control_protocol.decode(data, 1)
            self.assertEqual(record, control_protocol.Bind(1, 3, 1000, 42, 123, 17))
            fds = array.array('i'); fds.frombytes(ancillary[0][2][:fds.itemsize]); os.close(fds[0])
            broker_instance.pending_binds[1].set_result(control_protocol.BindResult(1, 0, b'e' * 16, b'g' * 16, 9, 1))
            result = await asyncio.wait_for(task, 1)
            self.assertEqual((result.window, result.generation), (9, 1))
        finally:
            if not task.done(): task.cancel(); await asyncio.gather(task, return_exceptions=True)
            control.close(); peer.close()

    async def test_unknown_stream_is_rejected(self):
        session = broker.Session(None, b'a' * 16, 1, None, Writer())
        session.session_ready.set()
        with self.assertRaises(ValueError):
            await session.message(Envelope(Kind.DATA, b'a' * 16, 1, 1, 2, 1, b'x'))
        session.bindings.finish(session.binding_generation)


if __name__ == '__main__': unittest.main()
