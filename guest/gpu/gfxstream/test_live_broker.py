import asyncio
import array
import os
from importlib.machinery import SourceFileLoader
import importlib.util
import json
from pathlib import Path
import sys
import socket
import struct
import tempfile
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
    def __init__(self): self.data = bytearray(); self.eof = False; self.transport = self
    def write(self, data): self.data.extend(data)
    async def drain(self): pass
    def write_eof(self): self.eof = True
    def close(self): pass
    def abort(self): pass
    def get_extra_info(self, _name): return object()
    async def wait_closed(self): pass


class ReadyReader(asyncio.StreamReader):
    """In-memory test boundary matching the no-read-ahead production interface."""
    async def wait_readable(self):
        if not self._buffer and not self._eof:
            await self._wait_for_data('test readiness')
    def close(self): pass


class LiveBrokerTests(unittest.IsolatedAsyncioTestCase):
    def test_frame_timing_uses_broker_intervals_and_bounded_aggregates(self):
        timing = broker.FrameTiming(True)
        surface, first, second = {}, {}, {}
        with mock.patch.object(broker.time, 'monotonic_ns', side_effect=[0, 100, 200, 300, 2_000_000_000, 2_000_000_100, 2_000_000_200, 2_000_000_300]), mock.patch('builtins.print') as output:
            timing.begin(surface, first)
            for name in ('result', 'release', 'retire'): timing.event(first, name)
            output.assert_not_called()
            timing.data_bytes = 1234
            timing.begin(surface, second)
            for name in ('result', 'release', 'retire'): timing.event(second, name)
            fields = dict(field.split('=') for field in output.call_args.args[0].split()[1:])
            self.assertEqual(fields['retired'], '2')
            self.assertEqual(fields['gap_sum_ns'], '2000000000')
            self.assertEqual(fields['result_sum_ns'], '200')
            self.assertEqual(fields['release_sum_ns'], '400')
            self.assertEqual(fields['retire_sum_ns'], '600')
            self.assertEqual(fields['data_bytes'], '1234')
            self.assertEqual(timing.frames, 0)
            self.assertEqual(timing.data_bytes, 0)
        with mock.patch.object(broker.time, 'monotonic_ns', return_value=10_000_000_000), mock.patch('builtins.print') as output:
            for _ in range(200):
                timing.started = 0
                timing.event(second, 'retire')
            self.assertEqual(output.call_count, 127)
            self.assertEqual(timing.records, 128)
            pending = {}
            timing.begin(surface, pending)
            self.assertFalse(pending)

    def test_frame_timing_is_opt_in_and_logging_failure_does_not_fail_transport(self):
        surface, pending = {}, {}
        disabled = broker.FrameTiming(False)
        with mock.patch('builtins.print') as output:
            disabled.begin(surface, pending)
            disabled.event(pending, 'retire')
            output.assert_not_called()
            self.assertFalse(surface)
            self.assertFalse(pending)
        timing = broker.FrameTiming(True)
        with mock.patch.object(broker.time, 'monotonic_ns', side_effect=[0, 3_000_000_000]), mock.patch('builtins.print', side_effect=BrokenPipeError):
            timing.begin(surface, pending)
            timing.event(pending, 'retire')
            self.assertEqual(timing.records, 1)

    def test_surface_progress_is_opt_in_bounded_and_metadata_only(self):
        with mock.patch.dict(os.environ, {}, clear=True):
            session = broker.Session(None, b'a' * 16, 1, None, Writer())
        with mock.patch('builtins.print') as output:
            session.surface_progress('received_from_guest', 25)
            output.assert_not_called()
            session.progress_enabled = True
            session.surface_progress('received_from_guest', 5)
            for _ in range(200): session.surface_progress('received_from_guest', 25)
            self.assertEqual(output.call_count, 129)
            self.assertEqual(output.call_args_list[-1].args[0], 'CABOOSE_GPU_SURFACE_PROGRESS limit=128')
            self.assertIn('kind=25', output.call_args_list[0].args[0])
        with mock.patch('builtins.print', side_effect=BrokenPipeError):
            session.progress_count = 0
            session.surface_progress('received_from_guest', 25)

    async def test_normal_close_is_queued_only_after_native_retirement(self):
        writer = Writer()
        session = broker.Session(None, b'a' * 16, 1, None, writer)
        with self.assertRaises(RuntimeError): await session.close_after_retirement()
        session.revoking = True
        with self.assertRaises(RuntimeError): await session.close_after_retirement()
        session.send(Kind.REVOKE)
        session.revoked.set()
        sender = asyncio.create_task(session.send_loop())
        try:
            await session.close_after_retirement()
            self.assertEqual(bytes(writer.data)[-4:], b'\x88\x02\x03\xe8')
            self.assertGreater(len(writer.data), 4)
            with self.assertRaises(ConnectionError): session.send(Kind.REVOKE)
        finally:
            sender.cancel(); await asyncio.gather(sender, return_exceptions=True)
            session.bindings.finish(session.binding_generation)

    async def test_indexed_session_requires_exact_v4_hello(self):
        session = broker.Session(None, b'a' * 16, 1, None, Writer(), indexed=True)
        expected = b'CBGLREF1' + struct.pack('<II', 4, 0x70) + bytes.fromhex(
            '20d3bb2e30337cabf0febb006ed102ab25ccf6d9ddbfaf624c7e68f9040969c0')
        self.assertEqual(session.hello, expected)
        vectors = json.loads((HERE.parent / 'broker' / 'live-v4-vectors.json').read_text())
        golden = next(v for v in vectors if v['kind'] == 'SESSION_READY')
        self.assertEqual(session.hello, bytes.fromhex(golden['payload']))
        for bad in (broker.HELLO, expected[:12] + struct.pack('<I', 0xf0) + expected[16:]):
            with self.assertRaises(ValueError):
                await session.message(Envelope(Kind.SESSION_READY, b'a' * 16, 1, 0, 0, 1, bad))
        await session.message(Envelope(Kind.SESSION_READY, b'a' * 16, 1, 0, 0, 1, expected))
        self.assertTrue(session.session_ready.is_set())
        session.bindings.finish(session.binding_generation)

    async def test_indexed_swapchain_real_reply_correlation(self):
        values = json.loads((HERE.parent / 'broker' / 'live-swapchain-vectors.json').read_text())
        vectors = {item['name']: bytes.fromhex(item['payload']) for item in values}
        state = broker.IndexedSurface()
        state.send(25, vectors['create'][40:])
        state.reply(26, vectors['created'])
        state.send(27, vectors['map'][40:])
        state.reply(28, vectors['mapped'])
        state.send(29, vectors['acquire'][40:])
        with self.assertRaises(ValueError): state.send(29, vectors['acquire'][40:])
        state.send(31, vectors['cancel-acquire'][40:])  # cancellation can race actual acquisition
        state.reply(30, vectors['acquired'])
        index = struct.unpack_from('<I', vectors['acquired'], 76)[0]
        self.assertIn(index, state.swaps[5]['acquired'])  # never erase a successful native result
        state.send(31, vectors['cancel-acquire'][40:])  # completed acquire cancellation is a no-op
        state.send(34, vectors['indexed-present'][40:])
        with self.assertRaises(ValueError): state.send(34, vectors['indexed-present'][40:])
        state.send(32, vectors['retire-swapchain'][40:])
        state.reply(33, vectors['retired-swapchain'])
        self.assertFalse(state.swaps)
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
        frame, _charge = session.pending.get_nowait()
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
        reader, writer = ReadyReader(), Writer()
        reader.feed_data(broker.HELLO + b'guest request'); reader.feed_eof()
        decoder = Decoder(b'a' * 16, 1)
        async def next_frame(kind):
            wire, _charge = await asyncio.wait_for(session.pending.get(), 1)
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
            if session.lifecycle_tasks:
                await asyncio.wait_for(asyncio.gather(*tuple(session.lifecycle_tasks)), 1)
        self.assertEqual(writer.data, broker.HELLO + b'reply')
        self.assertTrue(writer.eof)
        self.assertFalse(session.processes)
        session.bindings.finish(session.binding_generation)

    @unittest.skipUnless(sys.platform == 'linux', 'Linux peer pidfd')
    async def test_creator_exit_drains_fin_then_admits_fresh_process(self):
        # A genuine connected creator exits before the broker gets EOF/native FIN.
        # Kernel pidfd death must not poison the retained retirement-only binding.
        session = broker.Session(None, b'a' * 16, 1, None, Writer())
        session.session_ready.set()
        decoder = Decoder(b'a' * 16, 1)
        async def next_frame(kind):
            wire, _charge = await asyncio.wait_for(session.pending.get(), 2)
            offset = 4 if wire[1] == 126 else 10 if wire[1] == 127 else 2
            got = []; decoder.feed(wire[offset:], got.append)
            self.assertEqual(got[0].kind, kind)
            return got[0]
        previous = 0
        try:
            for _ in range(2):
                with tempfile.TemporaryDirectory() as directory:
                    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                    path = directory + '/stream'
                    listener.bind(path); listener.listen(1)
                    control_r, control_w = os.pipe()
                    ready_r, ready_w = os.pipe()
                    pid = os.fork()
                    if pid == 0:
                        try:
                            listener.close(); os.close(control_w); os.close(ready_r)
                            client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                            client.connect(path); client.sendall(broker.HELLO)
                            echo = b''
                            while len(echo) < 48: echo += client.recv(48 - len(echo))
                            os.write(ready_w, b'r'); os.close(ready_w)
                            os.read(control_r, 1)
                            client.close()
                        finally: os._exit(0)
                    os.close(control_r); os.close(ready_w)
                    accepted, _ = listener.accept(); listener.close()
                    accepted.setblocking(False)
                    connected = asyncio.get_running_loop().create_future()
                    def connected_local(unused_reader, local_writer):
                        connected.set_result((broker.LocalSocketReader(local_writer), local_writer))
                    await asyncio.get_running_loop().connect_accepted_socket(
                        lambda: asyncio.StreamReaderProtocol(asyncio.StreamReader(), connected_local), accepted)
                    reader, writer = await connected
                    task = asyncio.create_task(session.local(reader, writer))
                    reaped = False
                    try:
                        opened = await next_frame(Kind.PROCESS_OPEN)
                        self.assertGreater(opened.process, previous); previous = opened.process
                        await session.message(Envelope(Kind.PROCESS_READY, b'a'*16, 1, opened.process, 0, 1))
                        stream = await next_frame(Kind.STREAM_OPEN)
                        await session.message(Envelope(Kind.STREAM_READY, b'a'*16, 1, opened.process, stream.stream, 2))
                        readable = asyncio.get_running_loop().create_future()
                        loop = asyncio.get_running_loop()
                        loop.add_reader(ready_r, lambda: readable.done() or readable.set_result(True))
                        try:
                            await asyncio.wait_for(readable, 2)
                            self.assertEqual(os.read(ready_r, 1), b'r')
                        finally: loop.remove_reader(ready_r)
                        os.close(ready_r); ready_r = -1
                        # Force creator death before the event loop can deliver EOF.
                        os.write(control_w, b'x'); os.close(control_w); control_w = -1
                        os.waitpid(pid, 0); reaped = True
                        await next_frame(Kind.FIN)
                        self.assertIn(opened.process, session.processes)
                        # Discard reverse data for the exited peer, but require real FIN.
                        await session.message(Envelope(Kind.DATA, b'a'*16, 1, opened.process, stream.stream, 3, b'late reply'))
                        self.assertFalse(session.streams[stream.stream]['remote_fin'].is_set())
                        await session.message(Envelope(Kind.FIN, b'a'*16, 1, opened.process, stream.stream, 4))
                        stopped = await next_frame(Kind.PROCESS_STOP)
                        self.assertIn(opened.process, session.processes)
                        await session.message(Envelope(Kind.PROCESS_RETIRED, b'a'*16, 1, stopped.process, 0, 5))
                        await asyncio.wait_for(task, 2)
                        if session.lifecycle_tasks:
                            await asyncio.wait_for(asyncio.gather(*tuple(session.lifecycle_tasks)), 2)
                        self.assertFalse(session.failed)
                        self.assertFalse(session.processes)
                    finally:
                        if ready_r >= 0: os.close(ready_r)
                        if control_w >= 0: os.close(control_w)
                        if not reaped: os.waitpid(pid, 0)
                        if not task.done(): task.cancel()
                        await asyncio.gather(task, return_exceptions=True)
                        writer.close(); await writer.wait_closed()
        finally:
            session.bindings.finish(session.binding_generation)

    async def test_dead_peer_without_local_eof_cannot_receive_native_fin(self):
        from test_process_binding import FakePeer
        session = broker.Session(None, b'a'*16, 1, None, Writer())
        session.session_ready.set()
        peer = FakePeer(42, 1)
        process, stream = session.bindings.bind(session.binding_generation, peer)
        ready = asyncio.Event(); ready.set()
        session.processes[process] = {'streams': {stream}, 'surfaces': set()}
        session.streams[stream] = {'process': process, 'writer': Writer(), 'ready': ready,
                                  'remote_fin': asyncio.Event(), 'local_eof': False}
        peer.close()
        with self.assertRaises(RuntimeError):
            await session.message(Envelope(Kind.FIN, b'a'*16, 1, process, stream, 1))
        self.assertFalse(session.streams[stream]['remote_fin'].is_set())
        with self.assertRaises(RuntimeError): session.bindings.bind(session.binding_generation, peer)
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
        session.processes[1] = {'ready': ready, 'retired': retired, 'stopping': False, 'streams': {2}, 'surfaces': set()}
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
        session.processes[1] = {'ready': ready, 'retired': retired, 'stopping': False, 'streams': {2}, 'surfaces': set()}
        session.streams[2] = {'process': 1, 'writer': Writer(), 'ready': stream_ready, 'remote_fin': remote_fin}
        session.bindings.identity = lambda _gen, _stream: (1, (1000, 42, 123))
        session.bindings.unbind_stream = mock.Mock()
        session.bindings.retire_process = mock.Mock()
        session.broker = mock.Mock(report_lifecycle=mock.AsyncMock())
        await session.message(Envelope(Kind.EXECUTOR_DRAIN, b'a' * 16, 1, 0, 0, 1))
        session.broker.report_lifecycle.assert_awaited_once_with(session, 5)
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
        reader, writer = ReadyReader(), HeldWriter()
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
        broker_instance.closing = asyncio.Event()
        import process_binding
        start = process_binding.process_start_ticks(Path(f'/proc/{os.getpid()}/stat').read_text())
        class Bindings:
            def duplicate_process_identity(self, generation, process):
                return (os.getuid(), os.getpid(), start), os.pidfd_open(os.getpid())
        session = mock.Mock()
        session.draining = False
        session.binding_generation = 1
        session.bindings = Bindings()
        ready = asyncio.Event(); ready.set()
        session.processes = {3: {'ready': ready, 'surfaces': set()}}
        session.surfaces = {}
        session.surface_epoch = None
        broker_instance.session = session
        task = asyncio.create_task(broker_instance.request_bind(session, 3, 17, b'e' * 16))
        try:
            await asyncio.sleep(0)
            data, ancillary, flags, _ = peer.recvmsg(80, socket.CMSG_SPACE(array.array('i').itemsize))
            record = control_protocol.decode(data, 1)
            self.assertEqual(record, control_protocol.Bind(1, 3, os.getuid(), os.getpid(), start, 17))
            fds = array.array('i'); fds.frombytes(ancillary[0][2][:fds.itemsize])
            try:
                self.assertEqual(broker.PeerIdentity.__module__, 'process_binding')
                self.assertEqual(process_binding.pidfd_pid(fds[0]), os.getpid())
            finally:
                os.close(fds[0])
            broker_instance.pending_binds[1].set_result(control_protocol.BindResult(1, 0, b'e' * 16, b'g' * 16, 9, 1))
            result = await asyncio.wait_for(task, 1)
            self.assertEqual((result.window, result.generation), (9, 1))
            task = asyncio.create_task(broker_instance.request_bind(session, 3, 17, b'e' * 16))
            await asyncio.sleep(0)
            _data, ancillary, _flags, _ = peer.recvmsg(80, socket.CMSG_SPACE(array.array('i').itemsize))
            fds = array.array('i'); fds.frombytes(ancillary[0][2][:fds.itemsize]); os.close(fds[0])
            broker_instance.pending_binds[2].set_result(control_protocol.BindResult(2, 0, b'x' * 16, b'g' * 16, 9, 2))
            with self.assertRaises(PermissionError): await asyncio.wait_for(task, 1)
            self.assertTrue(broker_instance.closing.is_set())
        finally:
            if not task.done(): task.cancel(); await asyncio.gather(task, return_exceptions=True)
            control.close(); peer.close()

    async def test_surface_retirement_receipt_precedes_compositor_release(self):
        session = broker.Session(None, b'a' * 16, 1, None, Writer())
        session.session_ready.set()
        key = (b'e' * 16, b'g' * 16, 7)
        process = {'ready': asyncio.Event(), 'retired': asyncio.Event(), 'stopping': False,
                   'streams': {2}, 'surfaces': {key}}
        session.processes[1] = process
        session.surfaces[key] = {'process': 1, 'retiring': False, 'retired': asyncio.Event()}
        session.broker = mock.Mock(send_control=mock.AsyncMock())
        record = control_protocol.RevokeGrant(*key)
        session.request_surface_retire(record)
        self.assertTrue(session.surfaces[key]['retiring'])
        payload = key[0] + key[1] + struct.pack('<Q', key[2])
        failure = payload + struct.pack('<iIiI', 5, 0, 0, 0)
        with self.assertRaises(ValueError):
            await session.message(Envelope(Kind.SURFACE_RETIRED, b'a' * 16, 1, 1, 0, 1, failure))
        session.broker.send_control.assert_not_awaited()
        success = payload + struct.pack('<iIiI', 0, 1, 0, 0)
        await session.message(Envelope(Kind.SURFACE_RETIRED, b'a' * 16, 1, 1, 0, 2, success))
        sent = session.broker.send_control.await_args.args[0]
        self.assertEqual(control_protocol.decode(sent, 0), control_protocol.GrantRetired(*key))
        self.assertFalse(process['surfaces'])
        self.assertFalse(session.surfaces)
        session.bindings.finish(session.binding_generation)

    async def test_crashed_process_surface_disconnect_waits_for_stream_fin_and_preserves_other_process(self):
        from test_process_binding import FakePeer
        session = broker.Session(None, b'a' * 16, 1, None, Writer(), indexed=True)
        session.session_ready.set()
        peer1 = FakePeer(71, 1)
        peer2 = FakePeer(72, 2)
        p1, s1 = session.bindings.bind(session.binding_generation, peer1)
        p2, s2 = session.bindings.bind(session.binding_generation, peer2)
        ready = asyncio.Event()
        ready.set()
        session.processes[p1] = {'ready': ready, 'retired': asyncio.Event(), 'stopping': False, 'streams': {s1}, 'surfaces': set()}
        session.processes[p2] = {'ready': ready, 'retired': asyncio.Event(), 'stopping': False, 'streams': {s2}, 'surfaces': set()}
        session.streams[s1] = {'process': p1, 'writer': Writer(), 'ready': ready, 'remote_fin': asyncio.Event(), 'local_eof': False, 'discard_reply': False}
        session.streams[s2] = {'process': p2, 'writer': Writer(), 'ready': ready, 'remote_fin': asyncio.Event(), 'local_eof': False, 'discard_reply': False}

        sent_envelopes = []
        session.send = mock.Mock(side_effect=lambda kind, process=0, stream=0, payload=b'', credit=None: sent_envelopes.append((kind, process, stream, payload)))
        control_records = []
        async def send_control(data, fd=None):
            control_records.append(control_protocol.decode(data, 0))
        instance = broker.Broker.__new__(broker.Broker)
        instance.send_control = mock.AsyncMock(side_effect=send_control)
        session.broker = instance

        key = (b'e' * 16, b'g' * 16, 7)
        identity = key[0] + key[1] + struct.pack('<Q', key[2])
        async def request_bind(_session, process_id, obj, space=0):
            self.assertEqual(process_id, p1)
            session.surfaces[key] = {
                'process': p1, 'window': 12, 'retiring': False, 'retire_sent': False,
                'revoke_requested': False, 'bind_sent': False, 'disconnected': False,
                'retired': asyncio.Event(),
            }
            session.processes[p1]['surfaces'].add(key)
            return control_protocol.BindResult(1, 0, key[0], key[1], 12, key[2])
        instance.request_bind = request_bind

        def cgls(kind, body):
            return struct.pack('<4sHHII', b'CGLS', 1, kind, 16 + len(body), 0) + body
        bound_ready = asyncio.Event()
        steps = [
            cgls(16, struct.pack('<QIIII', 8, 9, 0, 0, 0)),
            bound_ready,
            cgls(29, struct.pack('<QQQQQII', 5, 11, 21, 0, 1000, 1, 0)),
            b'',
        ]
        sock = mock.Mock()
        sock.fileno.return_value = 99
        def recvmsg(_size, _flags):
            if steps and isinstance(steps[0], asyncio.Event):
                if not steps[0].is_set():
                    raise BlockingIOError()
                steps.pop(0)
            data = steps.pop(0) if steps else b''
            return data, [], 0, None
        sock.recvmsg.side_effect = recvmsg
        sock.send.side_effect = lambda data: len(data)
        reader_cb = []
        loop = asyncio.get_running_loop()

        with mock.patch.object(broker.PeerIdentity, 'from_socket', return_value=FakePeer(71, 1)), \
             mock.patch.object(session.bindings, 'find_process', return_value=p1), \
             mock.patch.object(loop, 'add_reader', side_effect=lambda _fd, cb: reader_cb.append(cb)), \
             mock.patch.object(loop, 'remove_reader'), \
             mock.patch.object(broker.surface_wire, 'validate_surface'):
            task = asyncio.create_task(instance.surface_client(session, sock))
            try:
                await asyncio.sleep(0.01)
                self.assertEqual([item[0] for item in sent_envelopes], [Kind.SURFACE_BIND])
                await session.message(Envelope(Kind.SURFACE_BOUND, b'a' * 16, 1, p1, 0, 1, identity + struct.pack('<iIiI', 0, 1, 0, 0)))
                surface = session.surfaces[key]
                surface['indexed'].swaps[5] = {
                    'count': 3, 'mapping': False, 'mapped': True, 'retiring': False,
                    'acquire': None, 'last_acquire': None, 'acquired': set(),
                }
                bound_ready.set()
                for cb in tuple(reader_cb):
                    cb()
                await asyncio.sleep(0.02)

                # Process 1 crashed: peer1 is dead, surface socket closed while acquire 11 was pending and stream s1 is still active.
                peer1.open = False
                self.assertEqual([item[0] for item in sent_envelopes], [
                    Kind.SURFACE_BIND,
                    Kind.SWAPCHAIN_ACQUIRE,
                    Kind.SWAPCHAIN_CANCEL_ACQUIRE,
                ])
                self.assertEqual(sent_envelopes[-1][3], identity + struct.pack('<QQ', 5, 11))
                self.assertEqual(control_records, [control_protocol.RevokeRequest(*key)])

                # Compositor responds with RevokeGrant, but stream s1 for dead peer1 has not drained yet, so SURFACE_RETIRE waits.
                session.request_surface_retire(control_protocol.RevokeGrant(*key))
                self.assertTrue(surface['retiring'])
                self.assertFalse(surface['retire_sent'])
                self.assertEqual([item[0] for item in sent_envelopes], [
                    Kind.SURFACE_BIND,
                    Kind.SWAPCHAIN_ACQUIRE,
                    Kind.SWAPCHAIN_CANCEL_ACQUIRE,
                ])

                # Once stream s1 finishes draining, SURFACE_RETIRE is sent.
                session.streams.pop(s1)
                session.bindings.unbind_stream(session.binding_generation, s1)
                session.processes[p1]['streams'].remove(s1)
                session.maybe_send_surface_retire(key)
                self.assertTrue(surface['retire_sent'])
                self.assertEqual(sent_envelopes[-1][:2], (Kind.SURFACE_RETIRE, p1))

                # Phone replies with SURFACE_RETIRED (even if nativeErrno != 0 on a disconnected surface) -> GrantRetired + PROCESS_STOP.
                await session.message(Envelope(Kind.SURFACE_RETIRED, b'a' * 16, 1, p1, 0, 2, identity + struct.pack('<iIiI', 5, 0, 0, 0)))
                await asyncio.wait_for(task, 1)
                self.assertEqual(control_records[-1], control_protocol.GrantRetired(*key))
                self.assertEqual(sent_envelopes[-1][:2], (Kind.PROCESS_STOP, p1))
                await session.message(Envelope(Kind.PROCESS_RETIRED, b'a' * 16, 1, p1, 0, 3))
                await asyncio.sleep(0.02)

                # Session and Process 2 remain completely healthy.
                self.assertFalse(session.failed)
                self.assertNotIn(p1, session.processes)
                self.assertIn(p2, session.processes)
                self.assertIn(s2, session.streams)
            finally:
                if not task.done():
                    task.cancel()
                    await asyncio.gather(task, return_exceptions=True)
                session.bindings.finish(session.binding_generation)

    async def test_unknown_stream_is_rejected(self):
        session = broker.Session(None, b'a' * 16, 1, None, Writer())
        session.session_ready.set()
        with self.assertRaises(ValueError):
            await session.message(Envelope(Kind.DATA, b'a' * 16, 1, 1, 2, 1, b'x'))
        session.bindings.finish(session.binding_generation)

    async def test_surface_replies_require_matching_real_requests(self):
        session = broker.Session(None, b'a' * 16, 1, None, Writer())
        session.session_ready.set()
        key = (b'e' * 16, b'g' * 16, 7)
        identity = key[0] + key[1] + struct.pack('<Q', key[2])
        session.processes[1] = {}
        surface = {'process': 1, 'window': 12, 'replies': asyncio.Queue(maxsize=64),
                   'reply_bytes': 0, 'bound': None, 'queries': {3},
                   'verify_peer': lambda: None,
                   'presents': {4: {'result': False, 'release': False, 'terminal': False}}}
        session.surfaces[key] = surface
        bound = identity + struct.pack('<iIiI', 0, 1, 0, 0)
        await session.message(Envelope(Kind.SURFACE_BOUND, b'a' * 16, 1, 1, 0, 1, bound))
        self.assertTrue(surface['bound'])
        packet = surface['replies'].get_nowait()
        self.assertEqual(struct.unpack_from('<Q', packet, 16)[0], 12)
        with self.assertRaises(ValueError):
            await session.message(Envelope(Kind.SURFACE_BOUND, b'a' * 16, 1, 1, 0, 2, bound))
        release = identity + struct.pack('<Q', 4)
        await session.message(Envelope(Kind.SOURCE_RELEASED, b'a' * 16, 1, 1, 0, 3, release))
        with self.assertRaises(ValueError):
            await session.message(Envelope(Kind.SOURCE_RELEASED, b'a' * 16, 1, 1, 0, 4, release))
        self.assertIn(4, surface['presents'])
        session.bindings.finish(session.binding_generation)

    async def test_present_late_device_loss_and_rejected_capacity(self):
        session = broker.Session(None, b'a' * 16, 1, None, Writer())
        session.session_ready.set()
        key = (b'e' * 16, b'g' * 16, 7)
        identity = key[0] + key[1] + struct.pack('<Q', key[2])
        session.processes[1] = {}
        surface = {'process': 1, 'window': 12, 'replies': asyncio.Queue(maxsize=64), 'reply_bytes': 0,
                   'verify_peer': lambda: None, 'presents': {4: {'result': False, 'release': False, 'terminal': False}}}
        session.surfaces[key] = surface
        def result(serial, disposition, event, vk=0):
            return identity + struct.pack('<QiIiIII', serial, 0, 1, vk, 0, disposition, event)
        async def deliver(kind, payload):
            await session.message(Envelope(kind, b'a' * 16, 1, 1, 0, 1, payload))
        await deliver(Kind.PRESENT_RESULT, result(4, 1, 0))
        await deliver(Kind.SOURCE_RELEASED, identity + struct.pack('<Q', 4))
        await deliver(Kind.PRESENT_RESULT, result(4, 1, 1, -4))
        self.assertTrue(surface['presents'][4]['terminal'])
        with self.assertRaises(ValueError): await deliver(Kind.PRESENT_RESULT, result(4, 1, 1, -4))
        surface['presents'][5] = {'result': False, 'release': False, 'terminal': False}
        await deliver(Kind.PRESENT_RESULT, result(5, 0, 0, -3))
        self.assertNotIn(5, surface['presents'])
        with self.assertRaises(ValueError): await deliver(Kind.PRESENT_RESULT, result(5, 0, 0, -3))
        session.bindings.finish(session.binding_generation)

    async def test_frame_retirement_requires_actual_result_and_source_release(self):
        session = broker.Session(None, b'a' * 16, 1, None, Writer())
        session.session_ready.set()
        key = (b'e' * 16, b'g' * 16, 7)
        identity = key[0] + key[1] + struct.pack('<Q', key[2])
        session.processes[1] = {}
        surface = {'process': 1, 'window': 12, 'replies': asyncio.Queue(maxsize=64), 'reply_bytes': 0,
                   'verify_peer': lambda: None, 'presents': {9: {'result': True, 'release': False, 'terminal': False, 'swap': 5}}}
        session.surfaces[key] = surface
        retired = Envelope(Kind.PRESENT_RETIRED, b'a' * 16, 1, 1, 0, 1, identity + struct.pack('<QQ', 5, 9))
        with self.assertRaises(ValueError): await session.message(retired)  # v3 never accepts indexed replies
        with mock.patch.object(session, 'indexed_enabled', True):
            with self.assertRaises(ValueError): await session.message(retired)
            release = Envelope(Kind.SOURCE_RELEASED, b'a' * 16, 1, 1, 0, 2, identity + struct.pack('<Q', 9))
            await session.message(release)
            await session.message(retired)
            self.assertNotIn(9, surface['presents'])
            with self.assertRaises(ValueError): await session.message(retired)
            for serial in range(10, 110):
                surface['presents'][serial] = {'result': False, 'release': False, 'terminal': False, 'swap': 5}
                body = identity + struct.pack('<QiIiIII', serial, 0, 1, 0, 0, 1, 0)
                await session.message(Envelope(Kind.PRESENT_RESULT, b'a' * 16, 1, 1, 0, 3, body))
                await session.message(Envelope(Kind.SOURCE_RELEASED, b'a' * 16, 1, 1, 0, 4, identity + struct.pack('<Q', serial)))
                await session.message(Envelope(Kind.PRESENT_RETIRED, b'a' * 16, 1, 1, 0, 5, identity + struct.pack('<QQ', 5, serial)))
                while not surface['replies'].empty():
                    packet = surface['replies'].get_nowait(); surface['reply_bytes'] -= len(packet)
                self.assertFalse(surface['presents'])
        session.bindings.finish(session.binding_generation)

    async def test_surface_reply_does_not_outlive_original_peer(self):
        session = broker.Session(None, b'a' * 16, 1, None, Writer())
        session.session_ready.set()
        key = (b'e' * 16, b'g' * 16, 7)
        identity = key[0] + key[1] + struct.pack('<Q', key[2])
        session.processes[1] = {}
        def dead(): raise PermissionError('original peer exited')
        surface = {'process': 1, 'window': 12, 'replies': asyncio.Queue(), 'verify_peer': dead}
        session.surfaces[key] = surface
        payload = identity + struct.pack('<iIiI', 0, 1, 0, 0)
        with self.assertRaises(PermissionError):
            await session.message(Envelope(Kind.SURFACE_BOUND, b'a' * 16, 1, 1, 0, 1, payload))
        self.assertTrue(surface['replies'].empty())
        session.bindings.finish(session.binding_generation)

    async def test_owner_surface_revocation_notifies_client_and_requests_compositor(self):
        session = broker.Session(None, b'a' * 16, 1, None, Writer())
        session.session_ready.set()
        key = (b'e' * 16, b'g' * 16, 7)
        identity = key[0] + key[1] + struct.pack('<Q', key[2])
        session.processes[1] = {}
        surface = {'process': 1, 'window': 12, 'replies': asyncio.Queue(), 'reply_bytes': 0,
                   'verify_peer': lambda: None, 'indexed': broker.IndexedSurface()}
        session.surfaces[key] = surface
        session.broker = mock.Mock(send_control=mock.AsyncMock())
        frame = Envelope(Kind.SURFACE_REVOKE_REQUEST, b'a' * 16, 1, 1, 0, 1, identity)
        with mock.patch.object(session, 'indexed_enabled', True):
            await session.message(frame)
            self.assertTrue(surface['indexed'].revoking)
            self.assertEqual(control_protocol.decode(session.broker.send_control.await_args.args[0], 0),
                             control_protocol.RevokeRequest(*key))
            self.assertEqual(surface['replies'].get_nowait()[16:], identity)
            with self.assertRaises(ValueError): await session.message(frame)
        session.bindings.finish(session.binding_generation)

    @unittest.skipUnless(sys.platform == 'linux', 'Linux AF_UNIX SOCK_SEQPACKET')
    async def test_local_surface_forwards_real_reply_over_seqpacket(self):
        local, client = socket.socketpair(socket.AF_UNIX, socket.SOCK_SEQPACKET)
        local.setblocking(False); client.setblocking(False)
        session = broker.Session(None, b'a' * 16, 1, None, Writer())
        session.session_ready.set()
        session.processes[1] = {'surfaces': set()}
        session.send = mock.Mock()
        peer = mock.Mock()
        result = control_protocol.BindResult(1, 0, b'e' * 16, b'g' * 16, 12, 7)
        key = (result.epoch, result.grant, result.generation)
        async def bind(_session, process, obj):
            self.assertEqual((process, obj), (1, 9))
            session.surfaces[key] = {'process': 1, 'window': 12, 'retiring': False, 'retired': asyncio.Event()}
            return result
        instance = broker.Broker.__new__(broker.Broker)
        instance.request_bind = bind
        loop = asyncio.get_running_loop()
        with mock.patch.object(broker.PeerIdentity, 'from_socket', return_value=peer), \
             mock.patch.object(session.bindings, 'find_process', return_value=1):
            task = asyncio.create_task(instance.surface_client(session, local))
            try:
                body = struct.pack('<QIIII', 8, 9, 0, 0, 0)
                await loop.sock_sendall(client, struct.pack('<4sHHII', b'CGLS', 1, 16, 40, 0) + body)
                for _ in range(10):
                    if session.send.called: break
                    await asyncio.sleep(0)
                self.assertEqual(session.send.call_args.args[0], Kind.SURFACE_BIND)
                self.assertEqual(session.send.call_args.kwargs['payload'][-8:], bytes(8))
                payload = result.epoch + result.grant + struct.pack('<Q', 7) + struct.pack('<iIiI', 0, 1, 0, 0)
                await session.message(Envelope(Kind.SURFACE_BOUND, b'a' * 16, 1, 1, 0, 1, payload))
                reply = await asyncio.wait_for(loop.sock_recv(client, 256), 1)
                self.assertEqual(reply[:4], b'CGLS')
                self.assertEqual(struct.unpack_from('<Q', reply, 16)[0], 12)
                self.assertEqual(reply[24:], payload)
            finally:
                task.cancel()
                await asyncio.gather(task, return_exceptions=True)
                client.close()
                session.bindings.finish(session.binding_generation)

    @unittest.skipUnless(sys.platform == 'linux', 'Linux AF_UNIX SOCK_SEQPACKET')
    async def test_local_indexed_sequence_preserves_native_frame_retirement(self):
        local, client = socket.socketpair(socket.AF_UNIX, socket.SOCK_SEQPACKET)
        local.setblocking(False); client.setblocking(False)
        session = broker.Session(None, b'a' * 16, 1, None, Writer(), indexed=True)
        session.session_ready.set(); session.processes[1] = {'surfaces': set()}
        session.send = mock.Mock()
        peer = mock.Mock(); peer.alive.return_value = True
        result = control_protocol.BindResult(1, 0, b'e' * 16, b'g' * 16, 12, 7)
        identity = result.epoch + result.grant + struct.pack('<Q', result.generation)
        key = (result.epoch, result.grant, result.generation)
        values = json.loads((HERE.parent / 'broker' / 'live-swapchain-vectors.json').read_text())
        vectors = {item['name']: bytes.fromhex(item['payload']) for item in values}
        async def bind(_session, _process, _obj):
            session.surfaces[key] = {'process': 1, 'window': 12, 'retiring': False, 'retired': asyncio.Event()}
            return result
        instance = broker.Broker.__new__(broker.Broker); instance.request_bind = bind
        loop = asyncio.get_running_loop()
        async def local_send(kind, body):
            data = struct.pack('<4sHHII', b'CGLS', 1, kind, 16 + len(body), 0) + body
            count = session.send.call_count
            await loop.sock_sendall(client, data)
            for _ in range(100):
                if session.send.call_count > count: return
                await asyncio.sleep(.001)
            self.fail('surface request was not forwarded')
        async def remote(kind, payload):
            frame = Envelope(Kind(kind), b'a' * 16, 1, 1, 0, 1, identity + payload[40:])
            await session.message(frame)
            reply = await asyncio.wait_for(loop.sock_recv(client, 1024), 1)
            self.assertEqual(struct.unpack_from('<H', reply, 6)[0], kind)
        with mock.patch.object(broker.PeerIdentity, 'from_socket', return_value=peer), \
             mock.patch.object(session.bindings, 'find_process', return_value=1):
            task = asyncio.create_task(instance.surface_client(session, local))
            try:
                await local_send(16, struct.pack('<QIIII', 8, 9, 0, 0, 0))
                bound = identity + struct.pack('<iIiI', 0, 1, 0, 0)
                await session.message(Envelope(Kind.SURFACE_BOUND, b'a' * 16, 1, 1, 0, 1, bound))
                await asyncio.wait_for(loop.sock_recv(client, 1024), 1)
                for req, name, reply_kind, reply_name in ((25, 'create', 26, 'created'),
                        (27, 'map', 28, 'mapped'), (29, 'acquire', 30, 'acquired')):
                    await local_send(req, vectors[name][40:])
                    await remote(reply_kind, vectors[reply_name])
                await local_send(34, vectors['indexed-present'][40:])
                serial = struct.unpack_from('<Q', vectors['indexed-present'], 48)[0]
                first_waits = session.send.call_args.kwargs['payload'][80:]
                rejected = identity + struct.pack('<QiIiIII', serial, 0, 1, -3, 0, 0, 0)
                await remote(21, rejected)
                retry = bytearray(vectors['indexed-present'][40:])
                serial += 1
                struct.pack_into('<Q', retry, 8, serial)
                await local_send(34, retry)
                self.assertEqual(session.send.call_args.kwargs['payload'][80:], first_waits)
                result_body = identity + struct.pack('<QiIiIII', serial, 0, 1, 0, 0, 1, 0)
                await remote(21, result_body)
                await remote(22, identity + struct.pack('<Q', serial))
                self.assertIn(serial, session.surfaces[key]['presents'])
                await remote(36, identity + struct.pack('<QQ', 5, serial))
                self.assertNotIn(serial, session.surfaces[key]['presents'])
            finally:
                task.cancel(); await asyncio.gather(task, return_exceptions=True)
                client.close(); session.bindings.finish(session.binding_generation)




class TransportNegotiationTests(unittest.IsolatedAsyncioTestCase):
    async def test_exact_opt_in_requires_v4_and_actual_two_receipts(self):
        with mock.patch.dict(os.environ, {'CABOOSE_PRIVATE_GPU_DEFLATE': '1'}):
            with self.assertRaises(ValueError): broker.Session(None,b'a'*16,1,None,Writer())
            session=broker.Session(None,b'a'*16,1,None,Writer(),indexed=True)
        try:
            receipt=Envelope(Kind.TRANSPORT_READY,b'a'*16,1,0,0,2,broker.TRANSPORT_CONFIG)
            with self.assertRaises(ValueError): await session.message(receipt)
            self.assertFalse(session.session_ready.is_set())
            await session.message(Envelope(Kind.SESSION_READY,b'a'*16,1,0,0,1,broker.HELLO_V4))
            self.assertFalse(session.session_ready.is_set())
            wire,charge=session.pending.get_nowait()
            got=[]; Decoder(b'a'*16,1).feed(wire[2:],got.append)
            self.assertEqual(got[0].kind,Kind.TRANSPORT_CONFIG)
            self.assertEqual(got[0].payload,broker.TRANSPORT_CONFIG)
            self.assertEqual(charge,len(wire))
            for payload,process,stream in [(b'',0,0),(struct.pack('<II',1,65601),0,0),(broker.TRANSPORT_CONFIG,1,0),(broker.TRANSPORT_CONFIG,0,1)]:
                with self.assertRaises(ValueError):
                    await session.message(Envelope(Kind.TRANSPORT_READY,b'a'*16,1,process,stream,2,payload))
            await session.message(receipt)
            self.assertTrue(session.session_ready.is_set())
            self.assertTrue(session.deflate_enabled)
            with self.assertRaises(ValueError): await session.message(receipt)
            with self.assertRaises(ValueError):
                await session.message(Envelope(Kind.SESSION_READY,b'a'*16,1,0,0,3,broker.HELLO_V4))
        finally: session.bindings.finish(session.binding_generation)

    async def test_default_v4_is_raw_and_unrequested_or_late_ack_fails(self):
        for setting in ('', 'true', '0', '1'):
            with mock.patch.dict(os.environ, {'CABOOSE_PRIVATE_GPU_DEFLATE':setting}):
                session=broker.Session(None,b'a'*16,1,None,Writer(),indexed=True)
            try:
                await session.message(Envelope(Kind.SESSION_READY,b'a'*16,1,0,0,1,broker.HELLO_V4))
                if setting == '1': session.draining=True
                else:
                    self.assertTrue(session.session_ready.is_set())
                    session.send(Kind.DATA,1,1,b'x'*1024)
                    wire,charge=session.pending.get_nowait()
                    self.assertEqual(wire[4:8],b'CGLV')
                    self.assertEqual(charge,len(wire))
                with self.assertRaises(ValueError):
                    await session.message(Envelope(Kind.TRANSPORT_READY,b'a'*16,1,0,0,2,broker.TRANSPORT_CONFIG))
            finally: session.bindings.finish(session.binding_generation)

    async def test_remote_does_not_report_ready_or_publish_socket_before_transport_ack(self):
        import uuid
        acknowledged=asyncio.Event(); hello_received=asyncio.Event(); published=asyncio.Event()
        class TestSession(broker.Session):
            async def read_loop(self):
                await self.message(Envelope(Kind.SESSION_READY,self.executor,1,0,0,1,broker.HELLO_V4))
                hello_received.set()
                await acknowledged.wait()
                await self.message(Envelope(Kind.TRANSPORT_READY,self.executor,1,0,0,2,broker.TRANSPORT_CONFIG))
                await asyncio.Future()
        async def publish(*args,**kwargs):
            published.set()
            raise OSError('stop at publication boundary')
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory); root.chmod(0o700); token=root/'token'; token.write_text('test')
            instance=object.__new__(broker.Broker)
            instance.token_file=token; instance.indexed=True; instance.lease=mock.Mock()
            instance.lease.admit.return_value=1
            instance.session=None; instance.socket_path=root/'gpu.sock'; instance.surface_path=None
            instance.report_lifecycle=mock.AsyncMock()
            reader=asyncio.StreamReader(); reader.feed_data(b'GET / HTTP/1.1\r\n\r\n')
            with mock.patch.dict(os.environ, {'CABOOSE_PRIVATE_GPU_DEFLATE':'1'}), mock.patch.object(broker,'Session',TestSession), mock.patch.object(broker,'admit',return_value=(None,uuid.UUID(bytes=b'a'*16),b'upgrade')), mock.patch.object(asyncio,'open_connection',return_value=(reader,Writer())), mock.patch.object(asyncio,'start_unix_server',side_effect=publish):
                task=asyncio.create_task(instance.remote(None))
                try:
                    await asyncio.wait_for(hello_received.wait(),1)
                    instance.report_lifecycle.assert_not_awaited()
                    instance.lease.ready.assert_not_called()
                    self.assertFalse(published.is_set())
                    self.assertFalse(instance.socket_path.exists())
                    acknowledged.set()
                    await asyncio.wait_for(task,1)
                    self.assertTrue(published.is_set())
                    self.assertEqual(instance.report_lifecycle.await_args_list[0].args[1],4)
                    instance.lease.ready.assert_called_once()
                finally:
                    task.cancel(); await asyncio.gather(task,return_exceptions=True)


if __name__ == '__main__': unittest.main()
