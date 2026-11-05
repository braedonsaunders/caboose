import asyncio
import contextlib
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
# Sessions here send raw DATA unless a test turns transport compression on.
os.environ.setdefault('CABOOSE_PRIVATE_GPU_DEFLATE', '0')
sys.path.insert(0, str(HERE.parent / 'broker'))
loader = SourceFileLoader('caboose_live_broker', str(HERE / 'caboose-gpu-broker'))
spec = importlib.util.spec_from_loader(loader.name, loader)
broker = importlib.util.module_from_spec(spec)
loader.exec_module(broker)
from live_protocol import Decoder, Envelope, Kind, encode
from live_compression import StreamDecompressor, zstd_stream_config
import live_zstd
from test_gpu_websocket import client_frame
import control_protocol



def hello(mask):
    return broker.HELLO_V4[:12] + struct.pack('<I', mask) + broker.HELLO_V4[16:]

class Writer:
    def __init__(self): self.data = bytearray(); self.eof = False; self.transport = self
    def write(self, data): self.data.extend(data)
    async def drain(self): pass
    def write_eof(self): self.eof = True
    def close(self): pass
    def abort(self): pass
    def is_closing(self): return False
    def get_write_buffer_size(self): return 0
    def get_extra_info(self, _name): return object()
    async def wait_closed(self): pass


class ReadyReader(asyncio.StreamReader):
    """In-memory test boundary matching the no-read-ahead production interface."""
    async def wait_readable(self):
        if not self._buffer and not self._eof:
            await self._wait_for_data('test readiness')
    def close(self): pass


class LiveBrokerTests(unittest.IsolatedAsyncioTestCase):
    @unittest.skipUnless(hasattr(socket, 'TCP_USER_TIMEOUT'), 'Linux TCP options')
    def test_executor_connection_finds_a_vanished_peer(self):
        listener = socket.socket(); listener.bind(('127.0.0.1', 0)); listener.listen(1)
        client = socket.create_connection(listener.getsockname())
        accepted, _ = listener.accept()
        try:
            broker.detect_dead_peer(accepted)
            self.assertEqual(accepted.getsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE), 1)
            self.assertEqual(accepted.getsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPIDLE), broker.DEAD_PEER_IDLE_S)
            self.assertEqual(accepted.getsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPCNT), broker.DEAD_PEER_PROBES)
            self.assertEqual(accepted.getsockopt(socket.IPPROTO_TCP, socket.TCP_USER_TIMEOUT), broker.DEAD_PEER_UNACKED_MS)
        finally:
            for item in (accepted, client, listener): item.close()
        local, remote = socket.socketpair()
        try:
            broker.detect_dead_peer(local)  # not TCP: left as it is
            self.assertEqual(local.getsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE), 0)
        finally:
            local.close(); remote.close()

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

    def test_present_rate_counts_ordered_presents_and_result_gaps(self):
        with mock.patch.dict(os.environ, {'CABOOSE_PRIVATE_GPU_PROGRESS': '1'}, clear=True):
            session = broker.Session(None, b'a' * 16, 1, None, Writer())
        clock = iter([0, 10, 20, 400_000_000, 410_000_000, 2_000_000_000])
        with mock.patch.object(broker.time, 'monotonic_ns', side_effect=lambda: next(clock)), \
                mock.patch('builtins.print') as output:
            session.present_rate('received_from_guest', Kind.SWAPCHAIN_PRESENT_ORDERED)   # 0
            session.present_rate('received_from_phone', Kind.PRESENT_RESULT)              # 10
            session.present_rate('received_from_guest', Kind.SWAPCHAIN_PRESENT)           # 20
            session.present_rate('received_from_guest', Kind.SWAPCHAIN_PRESENT_ORDERED)   # 400 ms
            session.present_rate('received_from_phone', Kind.PRESENT_RESULT)              # 410 ms
            session.present_rate('received_from_phone', Kind.SOURCE_RELEASED)             # 2 s
        line = output.call_args.args[0]
        self.assertIn('presented=3 ordered=2 results=2 released=1', line)
        self.assertIn('gap_max_ms=399 result_gap_max_ms=409', line)
        # Ordered presents reach the progress hook like every other surface control.
        with mock.patch.object(session, 'present_rate') as rate, mock.patch('builtins.print'):
            session.surface_progress('received_from_guest', Kind.SWAPCHAIN_PRESENT_ORDERED)
            rate.assert_called_once_with('received_from_guest', int(Kind.SWAPCHAIN_PRESENT_ORDERED))

    def test_executor_stats_report_the_phones_counters_every_five_seconds(self):
        import struct as _struct
        def record(**values):
            fields = dict.fromkeys(broker.ExecutorStats.FIELDS, 0)
            fields.update(values, size=96)
            return _struct.pack('<12Q', *(fields[k] for k in broker.ExecutorStats.FIELDS))
        stats = broker.ExecutorStats()
        with mock.patch('builtins.print') as output:
            # The first record is the baseline: totals since the phone's runtime started.
            self.assertIsNone(stats.receive(record(commands=500, decode_us=9_000), 0))
            self.assertIsNone(stats.receive(record(commands=600, outstanding=3, outstanding_max=7), 1_000_000_000))
            output.assert_not_called()
            line = stats.receive(record(commands=1500, decode_us=1_009_000, read_bytes=4096, read_wait_us=2_500_000,
                                        flush_us=40_000, submitted=300, completed=298, completion_us=2_980_000,
                                        gpu_busy_us=2_500_000, outstanding=2, outstanding_max=4), 5_000_000_000)
            self.assertRegex(line, r'^CABOOSE_GPU_EXECUTOR_STATS elapsed_ms=5000 commands=1000 decode_ms=1000 '
                                   r'read_bytes=4096 read_wait_ms=2500 flush_ms=40 submitted=300 completed=298 '
                                   r'completion_mean_us=10000 gpu_busy_pct=50\.0 outstanding=2 outstanding_max=7 '
                                   r'at=\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$')
            self.assertEqual(output.call_args.args[0], line)
        with self.assertRaises(ValueError):
            stats.receive(b'\0' * 95)

    def test_stats_request_goes_only_to_a_phone_that_declared_executor_stats(self):
        for features, expected in ((frozenset({'executor-stats'}), True), (frozenset(), False)):
            session = mock.Mock(features=features, stats_requested=False)
            broker.Session.request_stats(session)
            broker.Session.request_stats(session)
            if expected:
                session.send.assert_called_once_with(broker.Kind.STATS_REQUEST, payload=bytes([0xe8, 3, 0, 0, 0, 0, 0, 0]))
            else:
                session.send.assert_not_called()
            self.assertEqual(session.stats_requested, expected)

    def test_surface_stats_report_fps_and_bytes_every_five_seconds_without_opt_in(self):
        owner = {'to_phone': 1000, 'from_phone': 50}
        stats = broker.SurfaceStats(2, owner)
        with mock.patch.dict(os.environ, {}, clear=True), mock.patch('builtins.print') as output:
            stats.event('present', 0)
            owner['to_phone'] += 4000
            stats.event('result', 100_000_000)
            stats.event('present', 200_000_000)
            stats.event('released', 300_000_000)
            stats.event('present', 2_700_000_000)
            output.assert_not_called()
            owner['from_phone'] += 700
            stats.event('result', 5_000_000_000)
            line = output.call_args.args[0]
            self.assertRegex(line, r'^CABOOSE_GPU_SURFACE_STATS surface=2 elapsed_ms=5000 fps=0\.6 presented=3 '
                                   r'results=2 released=1 gap_max_ms=2500 to_phone_bytes=4000 from_phone_bytes=700 '
                                   r'at=\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$')
            # With its session's link, a window also reports compressed bytes and send waits.
            link = mock.Mock(wire_to_phone=100, send_blocked_ns=0)
            linked = broker.SurfaceStats(3, owner, link)
            linked.event('present', 0)
            link.wire_to_phone, link.send_blocked_ns = 1300, 40_000_000
            linked.event('present', 5_000_000_000)
            self.assertIn('link_bytes=1200 link_blocked_ms=40 at=', output.call_args.args[0])
            # The next window counts afresh.
            stats.event('present', 6_000_000_000)
            stats.event('present', 10_000_000_000)
            line = output.call_args.args[0]
            self.assertIn('elapsed_ms=5000 fps=0.4 presented=2 results=0 released=0 gap_max_ms=4000 '
                          'to_phone_bytes=0 from_phone_bytes=0', line)

    def test_present_trace_follows_its_flag_file_and_reports_presents_and_bytes(self):
        with tempfile.TemporaryDirectory() as runtime:
            trace = broker.PresentTrace({'XDG_RUNTIME_DIR': runtime})
            clock = iter(range(0, 10_000_000_000, 400_000_000))
            with mock.patch.object(broker.time, 'monotonic_ns', side_effect=lambda: next(clock)), \
                    mock.patch('builtins.print') as output:
                trace.surface('received_from_guest', int(Kind.SWAPCHAIN_PRESENT))  # 0 s: off
                output.assert_not_called()
                Path(runtime, 'caboose-gpu-present-trace').touch()
                trace.surface('received_from_guest', int(Kind.SWAPCHAIN_PRESENT))  # 0.4 s: not looked yet
                output.assert_not_called()
                trace.surface('received_from_phone', int(Kind.PRESENT_RESULT))  # 0.8 s: not looked yet
                trace.surface('received_from_guest', int(Kind.SWAPCHAIN_PRESENT_ORDERED))  # 1.2 s: on
                trace.surface('received_from_phone', int(Kind.PRESENT_RESULT))  # 1.6 s
                trace.surface('queued_to_phone', int(Kind.SWAPCHAIN_PRESENT))  # not traced, no clock
                trace.stream(to_phone=100)  # 2.0 s
                trace.stream(from_phone=7)
                trace.stream(to_phone=50)
                trace.stream(to_phone=1)
            lines = [c.args[0] for c in output.call_args_list]
            self.assertEqual(lines[0], 'CABOOSE_GPU_PRESENT event=present monotonic_ns=1200000000')
            self.assertEqual(lines[1], 'CABOOSE_GPU_PRESENT event=result monotonic_ns=1600000000')
            self.assertEqual(lines[2], 'CABOOSE_GPU_STREAM elapsed_ms=1200 to_phone_bytes=151 from_phone_bytes=7 '
                                       'monotonic_ns=3200000000')
            self.assertEqual(len(lines), 3)
        self.assertTrue(broker.PresentTrace({'CABOOSE_PRIVATE_GPU_PRESENT_TRACE': '1'}).enabled(0))
        self.assertFalse(broker.PresentTrace({}).enabled(0))

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

    async def test_one_read_of_many_small_frames_keeps_the_session(self):
        # The phone sends many small frames; hundreds can arrive in one read, and the
        # session must take them all instead of ending (it once ended at 64).
        left, right = socket.socketpair()
        left.setblocking(False); right.setblocking(False)
        guest_reader, guest_writer = await asyncio.open_connection(sock=left)
        phone_reader, phone_writer = await asyncio.open_connection(sock=right)
        session = broker.Session(None, b'a' * 16, 1, guest_reader, guest_writer, indexed=True, features={'executor-resume'})
        session.transport_config = None
        sender = asyncio.create_task(session.send_loop())
        receiver = asyncio.create_task(session.read_loop())
        try:
            session.send(Kind.SESSION, payload=session.hello)
            await asyncio.wait_for(phone_reader.readexactly(2 + 112), 1)
            ack = encode(Envelope(Kind.ACK, b'a' * 16, 1, 0, 0, 0, struct.pack('<Q', 0)))
            ready = encode(Envelope(Kind.SESSION_READY, b'a' * 16, 1, 0, 0, 1, session.hello))
            phone_writer.write(b''.join(client_frame(2, ack) for _ in range(300)) + client_frame(2, ready))
            await phone_writer.drain()
            await asyncio.wait_for(session.session_ready.wait(), 1)
            self.assertFalse(receiver.done())
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

    async def test_local_stream_answers_the_hello_before_receipts_and_relays_both_directions(self):
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
            # The openings, the hello's answer and the guest's data go out at once, in order: the
            # phone takes them in that order and answers the openings first.
            opened = await next_frame(Kind.PROCESS_OPEN)
            stream = await next_frame(Kind.STREAM_OPEN)
            data = await next_frame(Kind.DATA)
            self.assertEqual(data.payload, b'guest request')
            self.assertEqual(writer.data, broker.HELLO)
            await next_frame(Kind.FIN)
            # Replies are taken only after the phone's real receipts.
            with self.assertRaises(ValueError):
                await session.message(Envelope(Kind.DATA, b'a' * 16, 1, opened.process, stream.stream, 1, b'early'))
            await session.message(Envelope(Kind.PROCESS_READY, b'a' * 16, 1, opened.process, 0, 1))
            await session.message(Envelope(Kind.STREAM_READY, b'a' * 16, 1, opened.process, stream.stream, 2))
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

    async def test_an_opening_the_phone_never_answers_fails_the_session(self):
        session = broker.Session(None, b'a' * 16, 1, None, Writer())
        session.session_ready.set()
        process = {'ready': asyncio.Event()}
        stream = {'ready': asyncio.Event()}
        async def unanswered(event, timeout): raise asyncio.TimeoutError()
        with mock.patch.object(session, 'phone_answer', unanswered), mock.patch.object(session, 'fail') as fail:
            await session.opened(process, stream, 4, 9)
        fail.assert_called_once()
        self.assertIn('local stream 9 of process 4: no answer to its opening', fail.call_args[0][0])

    async def test_guest_handle_hello_is_echoed_only_when_the_phone_supports_it(self):
        everything = frozenset(broker.HELLO_FEATURES)
        cases = ((everything, broker.HELLO_V4_GUEST_HANDLES, broker.HELLO_V4_GUEST_HANDLES),
                 (frozenset(), broker.HELLO_V4_GUEST_HANDLES, broker.HELLO_V4),
                 (everything, broker.HELLO_V4, broker.HELLO_V4),
                 (everything, hello(0x3F0), hello(0x3F0)),
                 (frozenset(), hello(0x20070), hello(0x20070)),
                 (frozenset({'guest-handles'}), hello(0x3F0), hello(0xF0)))
        for supported, offered, expected in cases:
            with self.subTest(supported=sorted(supported), offered=offered[12:14].hex()):
                session = broker.Session(None, b'a' * 16, 1, None, Writer(), indexed=True, features=supported)
                session.session_ready.set()
                class Peer:
                    uid, pid, start_ticks = 1000, 42, 123
                    def alive(self): return True
                    def close(self): pass
                reader, writer = ReadyReader(), Writer()
                reader.feed_data(offered)
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
                    await session.message(Envelope(Kind.PROCESS_READY, b'a' * 16, 1, opened.process, 0, 1))
                    stream = await next_frame(Kind.STREAM_OPEN)
                    await session.message(Envelope(Kind.STREAM_READY, b'a' * 16, 1, opened.process, stream.stream, 2))
                    for _ in range(100):
                        if len(writer.data) >= 48: break
                        await asyncio.sleep(0.01)
                    self.assertEqual(writer.data[:48], expected)
                    trailer=session.cache_session if struct.unpack_from('<I',expected,12)[0] & broker.CACHE_SESSION else b''
                    self.assertEqual(writer.data[48:],trailer)
                    task.cancel()
                    with contextlib.suppress(asyncio.CancelledError): await task
                session.bindings.finish(session.binding_generation)

    async def test_cache_scope_changes_even_when_executor_identifiers_repeat(self):
        sessions=[broker.Session(None,b'a'*16,1,None,Writer(),indexed=True) for _ in range(2)]
        self.assertEqual(len(sessions[0].cache_session),32)
        self.assertNotEqual(sessions[0].cache_session,sessions[1].cache_session)
        for session in sessions: session.bindings.finish(session.binding_generation)

    async def test_plain_session_refuses_the_guest_handle_hello(self):
        session = broker.Session(None, b'a' * 16, 1, None, Writer(), features=frozenset({'guest-handles'}))
        self.assertFalse(session.features)

    def test_session_features_line_names_each_stage(self):
        line = broker.session_features_line(frozenset({'guest-handles', 'future-thing', 'other'}),
                                            frozenset({'guest-handles', 'other'}), frozenset({'guest-handles'}))
        self.assertEqual(line, 'CABOOSE_GPU_SESSION_FEATURES source=relay declared=future-thing,guest-handles,other '
                               'forwarded=guest-handles,other received=guest-handles bits=0x80')
        self.assertEqual(broker.session_features_line(None, frozenset(), frozenset()),
                         'CABOOSE_GPU_SESSION_FEATURES source=direct declared=- forwarded=- received=- bits=0x0')

    def test_hello_negotiation_grants_offered_phone_features(self):
        everything = frozenset(broker.HELLO_FEATURES)
        negotiate = broker.negotiate_hello
        self.assertEqual(negotiate(hello(0x70), everything), hello(0x70))
        self.assertEqual(negotiate(hello(0xF0), everything), hello(0xF0))
        self.assertEqual(negotiate(hello(0x270), everything), hello(0x270))
        self.assertEqual(negotiate(hello(0x3F0), frozenset({'completion-feed'})), hello(0x270))
        # Descriptor-set and command-buffer handles need guest handles themselves.
        self.assertEqual(negotiate(hello(0x1F0), frozenset({'guest-handle-arrays'})), hello(0x70))
        self.assertIsNone(negotiate(hello(0x170), everything))
        # The shader cache stands alone: it is granted with or without guest handles.
        self.assertEqual(negotiate(hello(0x2070), everything), hello(0x2070))
        self.assertEqual(negotiate(hello(0x3FF0), frozenset({'shader-cache'})), hello(0x2070))
        self.assertEqual(negotiate(hello(0x3FF0), everything - {'shader-cache'}), hello(0x1FF0))
        # So does the upload cache.
        self.assertEqual(negotiate(hello(0x8070), everything), hello(0x8070))
        self.assertEqual(negotiate(hello(0x8070), everything - {'upload-cache'}), hello(0x70))
        # Unknown bits, missing required bits, other versions and other sources are refused.
        self.assertEqual(negotiate(hello(0x470), everything), hello(0x470))
        self.assertIsNone(negotiate(hello(0x1070), everything))
        self.assertEqual(negotiate(hello(0x20070), frozenset()), hello(0x20070))
        self.assertIsNone(negotiate(hello(0x200070), everything))
        # Batched descriptor sets are granted only when the phone declared them; an older phone
        # leaves the process on per-call descriptor sets.
        self.assertEqual(negotiate(hello(0x40070), everything), hello(0x40070))
        self.assertEqual(negotiate(hello(0x40070), everything - {'batched-descriptor-sets'}), hello(0x70))
        self.assertEqual(negotiate(hello(0x5ff80 | 0x70), everything - {'batched-descriptor-sets'}), hello(0x1ff80 | 0x70))
        # So are batched sets with inline uniform blocks (0x80000), under their own name.
        self.assertEqual(negotiate(hello(0x80070), everything), hello(0x80070))
        self.assertEqual(negotiate(hello(0x80070), everything - {'batched-descriptor-sets-inline'}), hello(0x70))
        self.assertEqual(negotiate(hello(0x80070), everything - {'batched-descriptor-sets'}), hello(0x80070))
        # Guest-chosen set ids (0x100000) are granted when the phone declared them, and only with
        # guest handles; an older phone leaves the process asking for its pools' ids.
        self.assertEqual(negotiate(hello(0x1000F0), everything), hello(0x1000F0))
        self.assertEqual(negotiate(hello(0x1000F0), everything - {'guest-set-ids'}), hello(0xF0))
        self.assertIsNone(negotiate(hello(0x100070), everything))
        self.assertEqual(negotiate(hello(0x1000F0), everything - {'guest-handles'}), hello(0x70))
        # Completion payloads (0x200000) are granted when the phone declared them, and only with
        # the completion feed; an older phone leaves the process asking for query results.
        self.assertEqual(negotiate(hello(0x200270), everything), hello(0x200270))
        self.assertEqual(negotiate(hello(0x200270), everything - {'completion-payloads'}), hello(0x270))
        self.assertEqual(negotiate(hello(0x200270), everything - {'completion-feed'}), hello(0x70))
        self.assertIsNone(negotiate(hello(0x200070), everything))
        # WAIT_SERIAL (0x400000) likewise needs the phone's declaration and the completion feed.
        self.assertEqual(negotiate(hello(0x400270), everything), hello(0x400270))
        self.assertEqual(negotiate(hello(0x400270), everything - {'wait-serial'}), hello(0x270))
        self.assertEqual(negotiate(hello(0x400270), everything - {'completion-feed'}), hello(0x70))
        self.assertIsNone(negotiate(hello(0x400070), everything))
        # Silent success (0x800000) is granted with guest handles and the completion feed; an
        # offer without either is malformed, and a phone that grants neither drops it.
        self.assertEqual(negotiate(hello(0x8002F0), everything), hello(0x8002F0))
        self.assertEqual(negotiate(hello(0x8002F0), everything - {'silent-success'}), hello(0x2F0))
        self.assertIsNone(negotiate(hello(0x800270), everything))
        self.assertIsNone(negotiate(hello(0x8000F0), everything))
        self.assertEqual(negotiate(hello(0x8002F0), everything - {'completion-feed'}), hello(0xF0))
        self.assertEqual(negotiate(hello(0x8002F0), everything - {'guest-handles'}), hello(0x270))
        # One-way start (0x1000000) is granted with silent success, guest handles and the completion
        # feed; an offer without any of them is malformed, and a phone that grants silent success
        # but not one-way start (an older phone) leaves the process waiting for those replies.
        self.assertEqual(negotiate(hello(0x18002F0), everything), hello(0x18002F0))
        self.assertEqual(negotiate(hello(0x18002F0), everything - {'one-way-start'}), hello(0x8002F0))
        self.assertEqual(negotiate(hello(0x18002F0), everything - {'silent-success'}), hello(0x2F0))
        self.assertIsNone(negotiate(hello(0x10002F0), everything))
        self.assertIsNone(negotiate(hello(0x1800270), everything))
        self.assertIsNone(negotiate(hello(0x18000F0), everything))
        # Buffer view handles need guest handles too.
        self.assertEqual(negotiate(hello(0x100F0), everything), hello(0x100F0))
        self.assertEqual(negotiate(hello(0x100F0), everything - {'guest-buffer-views'}), hello(0xF0))
        self.assertEqual(negotiate(hello(0x100F0), frozenset({'guest-buffer-views'})), hello(0x70))
        self.assertIsNone(negotiate(hello(0x10070), everything))
        self.assertIsNone(negotiate(hello(0x30), everything))
        # Executor resume is granted only when the phone declared it.
        self.assertEqual(negotiate(hello(0x4070), everything), hello(0x4070))
        self.assertEqual(negotiate(hello(0x4070), everything - {'executor-resume'}), hello(0x70))
        self.assertIsNone(negotiate(broker.HELLO, everything))
        self.assertIsNone(negotiate(hello(0x70)[:47] + b'\0', everything))
        self.assertIsNone(negotiate(hello(0x70)[:47], everything))

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

    async def test_writer_whose_peer_went_away_is_closed(self):
        # A peer that shut its socket while writes were pending ends the transport with an
        # error: that is a finished close, not one that timed out.
        class BrokenPeer(Writer):
            async def wait_closed(self): raise BrokenPipeError()
        self.assertTrue(await broker.close_owned_writer(BrokenPeer(), abort=False, timeout=0.1))

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
        session.surface_count = 0
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
            # A process that ends while the compositor answers (a splash window that exits at
            # once) has its grant handed back, and the broker goes on.
            ended = session.processes.pop(3)
            broker_instance.pending_binds[2].set_result(control_protocol.BindResult(2, 0, b'e' * 16, b'k' * 16, 9, 2))
            with self.assertRaisesRegex(PermissionError, 'ended process'): await asyncio.wait_for(task, 1)
            self.assertFalse(broker_instance.closing.is_set())
            revoke, _ancillary, _flags, _ = peer.recvmsg(80)
            self.assertEqual(control_protocol.decode(revoke, 0), control_protocol.RevokeRequest(b'e' * 16, b'k' * 16, 2))
            session.processes[3] = ended
            task = asyncio.create_task(broker_instance.request_bind(session, 3, 17, b'e' * 16))
            await asyncio.sleep(0)
            _data, ancillary, _flags, _ = peer.recvmsg(80, socket.CMSG_SPACE(array.array('i').itemsize))
            fds = array.array('i'); fds.frombytes(ancillary[0][2][:fds.itemsize]); os.close(fds[0])
            broker_instance.pending_binds[3].set_result(control_protocol.BindResult(3, 0, b'x' * 16, b'g' * 16, 9, 3))
            with self.assertRaises(PermissionError): await asyncio.wait_for(task, 1)
            self.assertTrue(broker_instance.closing.is_set())
        finally:
            if not task.done(): task.cancel(); await asyncio.gather(task, return_exceptions=True)
            control.close(); peer.close()

    @unittest.skipUnless(sys.platform == 'linux', 'Linux AF_UNIX SOCK_SEQPACKET')
    async def test_a_listening_broker_outlives_its_compositor(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'control.sock'
            listener = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET)
            listener.bind(str(path)); listener.listen(2)
            instance = broker.Broker(None, Path(directory) / 'token', Path(directory) / 'gpu.sock', listener=listener)
            task = asyncio.create_task(instance.run())
            loop = asyncio.get_running_loop()
            async def connect():
                compositor = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET)
                compositor.setblocking(False)
                await loop.sock_connect(compositor, str(path))
                for _ in range(200):
                    if instance.control is not None and instance.compositor_pid == os.getpid(): break
                    await asyncio.sleep(0.005)
                return compositor
            try:
                first = await connect()
                self.assertEqual(instance.compositor_pid, os.getpid())
                # Its grants: one surface of a live session.
                key = (b'e' * 16, b'g' * 16, 7)
                session = mock.Mock()
                session.surfaces = {key: {}}
                session.surface_epoch = b'e' * 16
                instance.session = session
                first.close()
                for _ in range(200):
                    if instance.control is None: break
                    await asyncio.sleep(0.005)
                self.assertIsNone(instance.control)
                self.assertFalse(instance.closing.is_set())
                session.request_surface_retire.assert_called_once_with(control_protocol.RevokeGrant(*key))
                self.assertIsNone(session.surface_epoch)
                # Without a compositor grants are dropped and a bind cannot be asked.
                await instance.send_control(control_protocol.encode_grant_retired(control_protocol.GrantRetired(*key)))
                with self.assertRaises(ConnectionError):
                    await instance.send_control(b'a bind request')
                # The next compositor hears of a ready executor, and nothing of the old grants.
                instance.lifecycle = control_protocol.encode_lifecycle(
                    control_protocol.ExecutorLifecycle(4, b'x' * 16, 3))
                second = await connect()
                record = control_protocol.decode(await asyncio.wait_for(loop.sock_recv(second, 256), 1), 0)
                self.assertEqual(record, control_protocol.ExecutorLifecycle(4, b'x' * 16, 3))
                await instance.send_control(control_protocol.encode_grant_retired(control_protocol.GrantRetired(*key)))
                fresh = control_protocol.GrantRetired(b'n' * 16, b'g' * 16, 8)
                await instance.send_control(control_protocol.encode_grant_retired(fresh))
                self.assertEqual(control_protocol.decode(await asyncio.wait_for(loop.sock_recv(second, 256), 1), 0), fresh)
                second.close()
            finally:
                instance.closing.set()
                await asyncio.wait_for(task, 5)

    async def test_a_late_bind_answer_is_logged_and_its_grant_handed_back(self):
        broker_instance = broker.Broker.__new__(broker.Broker)
        broker_instance.pending_binds = {}
        broker_instance.tasks = set()
        sent = []
        async def send_control(data, fd=None): sent.append(data)
        broker_instance.send_control = send_control
        with mock.patch('builtins.print') as output:
            broker_instance.bind_answered(control_protocol.BindResult(7, 0, b'e' * 16, b'g' * 16, 9, 3))
            broker_instance.bind_answered(control_protocol.BindResult(8, 1, b'e' * 16, b'h' * 16, 9, 4))
            await asyncio.sleep(0)
        self.assertIn('late bind answer for request 7 status 0', output.call_args_list[0].args[0])
        self.assertEqual(sent, [control_protocol.encode_revoke_request(control_protocol.RevokeRequest(b'e' * 16, b'g' * 16, 3))])
        # A pending request takes its answer.
        future = asyncio.get_running_loop().create_future()
        broker_instance.pending_binds[9] = future
        answer = control_protocol.BindResult(9, 0, b'e' * 16, b'i' * 16, 9, 5)
        broker_instance.bind_answered(answer)
        self.assertEqual(future.result(), answer)

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
        priorities = []
        def send(kind, process=0, stream=0, payload=b'', credit=None, priority=False):
            sent_envelopes.append((kind, process, stream, payload))
            priorities.append(priority)
        session.send = mock.Mock(side_effect=send)
        control_records = []
        async def send_control(data, fd=None):
            control_records.append(control_protocol.decode(data, 0))
        instance = broker.Broker.__new__(broker.Broker)
        instance.send_control = mock.AsyncMock(side_effect=send_control)
        session.broker = instance

        key = (b'e' * 16, b'g' * 16, 7)
        identity = key[0] + key[1] + struct.pack('<Q', key[2])
        async def request_bind(_session, process_id, obj, space=0, probe=False):
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
                # The process's acquire goes ahead of queued DATA; the broker's own cancellation
                # of it, after the process went, keeps its place.
                self.assertEqual(priorities, [False, True, False])
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
        async def bind(_session, process, obj, space=0, probe=False):
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
        async def bind(_session, _process, _obj, space=0, probe=False):
            session.surfaces[key] = {'process': 1, 'window': 12, 'retiring': False, 'retired': asyncio.Event(),
                                     'stats': broker.SurfaceStats(1, session.processes[1])}
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
    @unittest.skipUnless(live_zstd.available(), 'libzstd 1.5 is not installed')
    async def test_zstd_stream_for_a_phone_that_decodes_it(self):
        for deflate in ('', '1'):
            with mock.patch.dict(os.environ, {'CABOOSE_PRIVATE_GPU_DEFLATE': deflate}):
                session = broker.Session(None, b'a'*16, 1, None, Writer(), indexed=True, features={'zstd-stream'})
            try:
                await session.message(Envelope(Kind.SESSION_READY, b'a'*16, 1, 0, 0, 1, broker.HELLO_V4))
                self.assertFalse(session.session_ready.is_set())
                wire, _ = session.pending.get_nowait()
                got = []; Decoder(b'a'*16, 1).feed(wire[2:], got.append)
                self.assertEqual((got[0].kind, got[0].payload), (Kind.TRANSPORT_CONFIG, broker.CONFIG_ZSTD_STREAM))
                for refused in (broker.TRANSPORT_CONFIG, zstd_stream_config(28)):  # DEFLATE; a larger window
                    with self.assertRaises(ValueError):
                        await session.message(Envelope(Kind.TRANSPORT_READY, b'a'*16, 1, 0, 0, 2, refused))
                # The phone takes a 64 MiB window of the 128 MiB offered.
                await session.message(Envelope(Kind.TRANSPORT_READY, b'a'*16, 1, 0, 0, 2, zstd_stream_config(26)))
                self.assertTrue(session.session_ready.is_set())
                self.assertFalse(session.deflate_enabled)
                payloads = [b'abc' * 5000, os.urandom(65536), b'abc' * 5000]
                for payload in payloads:
                    session.send(Kind.DATA, 1, 1, payload)
                session.send(Kind.FIN, 1, 1)
                inflater, parser, envelopes = StreamDecompressor(26), Decoder(b'a'*16, 1), []
                parser.feed(encode(got[0]), lambda _: None)
                sizes = []
                while not session.pending.empty():
                    wire, charge = session.pending.get_nowait()
                    message = wire[{126: 4, 127: 10}.get(wire[1] & 127, 2):]
                    self.assertGreaterEqual(charge, len(wire))
                    self.assertLessEqual(charge, broker.DATA_CREDIT_BYTES)
                    if message[:4] == b'CGLZ':
                        sizes.append(len(message))
                        message = inflater.decompress(message)
                    parser.feed(message, envelopes.append)
                self.assertEqual([e.payload for e in envelopes], payloads + [b''])
                self.assertEqual(envelopes[-1].kind, Kind.FIN)
                self.assertEqual(len(sizes), 3)
                self.assertLess(sizes[2], 100)  # the third repeats the first, within the stream
            finally: session.bindings.finish(session.binding_generation)

    async def test_deflate_without_the_phones_zstd_stream(self):
        with mock.patch.dict(os.environ, {'CABOOSE_PRIVATE_GPU_DEFLATE': '1'}), \
                mock.patch.object(broker.live_zstd, 'available', return_value=False):
            session = broker.Session(None, b'a'*16, 1, None, Writer(), indexed=True, features={'zstd-stream'})
        try:
            self.assertEqual(session.transport_config, broker.TRANSPORT_CONFIG)
        finally: session.bindings.finish(session.binding_generation)

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

    async def test_v4_is_compressed_unless_turned_off_and_unrequested_or_late_ack_fails(self):
        for setting in ('', 'true', '0', '1'):
            with mock.patch.dict(os.environ, {'CABOOSE_PRIVATE_GPU_DEFLATE':setting}):
                session=broker.Session(None,b'a'*16,1,None,Writer(),indexed=True)
            try:
                await session.message(Envelope(Kind.SESSION_READY,b'a'*16,1,0,0,1,broker.HELLO_V4))
                if setting != '0': session.draining=True
                else:
                    self.assertTrue(session.session_ready.is_set())
                    session.send(Kind.DATA,1,1,b'x'*1024)
                    wire,charge=session.pending.get_nowait()
                    self.assertEqual(wire[4:8],b'CGLV')
                    self.assertEqual(charge,len(wire))
                with self.assertRaises(ValueError):
                    await session.message(Envelope(Kind.TRANSPORT_READY,b'a'*16,1,0,0,2,broker.TRANSPORT_CONFIG))
            finally: session.bindings.finish(session.binding_generation)

    async def test_remote_reports_ready_only_after_transport_ack_and_its_sockets(self):
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
                    # Ready is reported only once the sockets exist: a publication that fails
                    # never reports it.
                    self.assertNotIn(4,[call.args[1] for call in instance.report_lifecycle.await_args_list])
                    instance.lease.ready.assert_not_called()
                finally:
                    task.cancel(); await asyncio.gather(task,return_exceptions=True)

    async def test_abrupt_executor_end_retires_its_generation_before_the_lease_is_released(self):
        import uuid
        ready_reported=asyncio.Event()
        class TestSession(broker.Session):
            async def read_loop(self):
                await self.message(Envelope(Kind.SESSION_READY,self.executor,1,0,0,1,self.hello))
                await ready_reported.wait()
                raise ConnectionError('executor disconnected')
        class Server:
            def close(self): pass
            async def wait_closed(self): pass
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory); root.chmod(0o700); token=root/'token'; token.write_text('test')
            async def start_server(_callback, path):
                Path(path).touch(); return Server()
            instance=object.__new__(broker.Broker)
            instance.token_file=token; instance.indexed=False; instance.lease=broker.ExecutorLease()
            instance.session=None; instance.socket_path=root/'gpu.sock'; instance.surface_path=None
            instance.closing=asyncio.Event()
            reported=[]
            async def report(session, kind):
                # Retirement must reach the compositor while the generation still holds the
                # lease: a reconnect waits for its release and then reports ready.
                reported.append((kind, instance.lease.held(session.executor, session.generation)))
                if kind == 4: session.ready_reported = True; ready_reported.set()
                if kind == 5: session.lost_reported = True
                if kind == 6: session.retired_reported = True
            instance.report_lifecycle=report
            reader=asyncio.StreamReader(); reader.feed_data(b'GET / HTTP/1.1\r\n\r\n')
            with mock.patch.object(broker,'Session',TestSession), mock.patch.object(broker,'admit',return_value=(None,uuid.UUID(bytes=b'a'*16),b'upgrade')), mock.patch.object(asyncio,'open_connection',return_value=(reader,Writer())), mock.patch.object(asyncio,'start_unix_server',side_effect=start_server):
                await asyncio.wait_for(instance.remote(None),5)
            self.assertEqual(reported,[(4,True),(5,True),(6,True)])
            self.assertTrue(instance.lease.idle)
            self.assertIsNone(instance.session)

    async def test_a_new_executor_supersedes_one_that_lingers(self):
        # The phone made a new executor while the host still held the previous one's
        # transport: the new one is admitted, the old one is ended as a loss, not refused.
        import uuid
        aborted=asyncio.Event()
        class LingeringWriter(Writer):
            def abort(self): aborted.set()
        ready=[asyncio.Event(),asyncio.Event()]
        class TestSession(broker.Session):
            async def read_loop(self):
                await self.message(Envelope(Kind.SESSION_READY,self.executor,self.generation,0,0,1,self.hello))
                if self.generation == 1:
                    # The old connection looks alive until the broker ends it.
                    await aborted.wait()
                    raise ConnectionError('executor disconnected')
                await asyncio.Event().wait()
        class Server:
            def close(self): pass
            async def wait_closed(self): pass
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory); root.chmod(0o700); token=root/'token'; token.write_text('test')
            async def start_server(_callback, path):
                Path(path).touch(); return Server()
            instance=object.__new__(broker.Broker)
            instance.token_file=token; instance.indexed=False; instance.lease=broker.ExecutorLease()
            instance.session=None; instance.holder=None; instance.socket_path=root/'gpu.sock'; instance.surface_path=None
            instance.closing=asyncio.Event(); instance.warmup=None
            reported=[]
            async def report(session, kind):
                reported.append((session.generation, kind))
                if kind == 4: session.ready_reported = True; ready[session.generation-1].set()
                if kind == 5: session.lost_reported = True
                if kind == 6: session.retired_reported = True
            instance.report_lifecycle=report
            def connection(_sock=None, **_kw):
                reader=asyncio.StreamReader(); reader.feed_data(b'GET / HTTP/1.1\r\n\r\n')
                return reader, LingeringWriter()
            identities=iter([uuid.UUID(bytes=b'a'*16), uuid.UUID(bytes=b'b'*16)])
            def admit(*_args): return None, next(identities), b'upgrade'
            with mock.patch.object(broker,'Session',TestSession), mock.patch.object(broker,'admit',side_effect=admit), mock.patch.object(asyncio,'open_connection',side_effect=connection), mock.patch.object(asyncio,'start_unix_server',side_effect=start_server):
                first=asyncio.create_task(instance.remote(None))
                await asyncio.wait_for(ready[0].wait(),5)
                second=asyncio.create_task(instance.remote(None))
                await asyncio.wait_for(ready[1].wait(),5)
                await asyncio.wait_for(first,5)
                self.assertTrue(aborted.is_set())
                self.assertEqual(reported[:4],[(1,4),(1,5),(1,6),(2,4)])
                self.assertTrue(instance.lease.held(b'b'*16,2))
                self.assertIs(instance.holder.generation,2)
                instance.closing.set()
                second.cancel()
                with contextlib.suppress(asyncio.CancelledError): await second

    async def test_orderly_retirement_is_not_reported_twice(self):
        session=object.__new__(broker.Session)
        session.executor=b'a'*16; session.generation=1
        session.ready_reported=True; session.lost_reported=True; session.retired_reported=False
        instance=object.__new__(broker.Broker)
        sent=[]
        async def send_control(data): sent.append(data)
        instance.send_control=send_control
        await instance.report_lifecycle(session,6)
        self.assertTrue(session.retired_reported)
        self.assertEqual(len(sent),1)
        self.assertEqual(struct.unpack_from('<H',sent[0],6)[0],6)



class ProcessUsageTests(unittest.TestCase):
    def test_usage_is_counters_per_identified_process(self):
        processes = {
            1: {'pid': 40, 'start': 9, 'streams': {1, 2}, 'surfaces': {('a',)}, 'to_phone': 100, 'from_phone': 5, 'ready': object()},
            2: {'streams': set(), 'surfaces': set()},
        }
        self.assertEqual(broker.usage_record(processes), {'version': 1, 'processes': [
            {'pid': 40, 'start': 9, 'streams': 2, 'surfaces': 1, 'toPhoneBytes': 100, 'fromPhoneBytes': 5}]})

    def test_usage_file_is_replaced_atomically_and_private(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'usage.json'
            broker.write_usage(path, {'version': 1, 'processes': []})
            broker.write_usage(path, {'version': 1, 'processes': [{'pid': 1}]})
            self.assertEqual(json.loads(path.read_text()), {'version': 1, 'processes': [{'pid': 1}]})
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(sorted(p.name for p in Path(directory).iterdir()), ['usage.json'])

    def test_session_counts_bytes_each_way_for_its_processes(self):
        session = broker.Session.__new__(broker.Session)
        session.processes = {3: {'to_phone': 0, 'from_phone': 0}}
        session.failed = session.closing_ws = session.sender_stopped = False
        session.executor, session.generation, session.sequence = bytes(range(1, 17)), 1, 1
        session.deflate_enabled = False
        session.stream_compressor = None
        session.frame_timing = broker.FrameTiming(False)
        session.progress_enabled = False
        session.enqueue = lambda *args, **kwargs: None
        session.send(Kind.DATA, 3, 1, b'abcd')
        session.send(Kind.DATA, 7, 1, b'ignored')
        self.assertEqual(session.processes[3]['to_phone'], 4)


if __name__ == '__main__': unittest.main()


def written_envelopes(data):
    """The CGLV envelopes in the broker's server-to-phone WebSocket frames (unmasked)."""
    out, view = [], bytes(data)
    while view:
        size = view[1] & 127
        if size == 126: size, offset = struct.unpack('!H', view[2:4])[0], 4
        elif size == 127: size, offset = struct.unpack('!Q', view[2:10])[0], 10
        else: offset = 2
        body = view[offset:offset + size]
        view = view[offset + size:]
        magic, version, kind, length = struct.unpack_from('<4sHHI', body)
        sequence = struct.unpack_from('<Q', body, 56)[0]
        out.append((Kind(kind), sequence, body[64:64 + length]))
    return out


class ExecutorResumeTests(unittest.IsolatedAsyncioTestCase):
    """Executor resume (docs/gpu-live.md, "Resuming an executor") on the broker's side."""
    executor = b'a' * 16

    def session(self):
        return broker.Session(None, self.executor, 1, None, Writer(), indexed=True,
                              features={'executor-resume', 'completion-feed'})

    def phone(self, kind, sequence, payload=b''):
        return Envelope(kind, self.executor, 1, 0, 0, sequence, payload)

    async def drained(self, session):
        for _ in range(20): await asyncio.sleep(0)

    async def test_retains_until_acknowledged_and_resumes_after_what_the_phone_had(self):
        session = self.session()
        sender = asyncio.create_task(session.send_loop())
        try:
            session.send_unsequenced(Kind.ACK, struct.pack('<Q', 0))
            session.send(Kind.SESSION, payload=session.hello)
            for _ in range(3): session.send(Kind.REVOKE)
            await self.drained(session)
            sent = written_envelopes(session.writer.data)
            self.assertEqual([(k, s) for k, s, _ in sent], [(Kind.ACK, 0), (Kind.SESSION, 1), (Kind.REVOKE, 2), (Kind.REVOKE, 3), (Kind.REVOKE, 4)])
            self.assertEqual([s for s, _ in session.retained], [1, 2, 3, 4])
            await session.message(self.phone(Kind.ACK, 0, struct.pack('<Q', 2)))
            self.assertEqual([s for s, _ in session.retained], [3, 4])
            # A splice: the phone had 3; the broker answers with its RESUME and the nonce,
            # then sends 4 again, ahead of anything queued after.
            session.writer.data.clear()
            nonce = b'n' * 16
            await session.message(self.phone(Kind.RESUME, 0, struct.pack('<QQ16s', 3, 0, nonce)))
            session.send(Kind.REVOKE)
            await self.drained(session)
            sent = written_envelopes(session.writer.data)
            self.assertEqual([(k, s) for k, s, _ in sent], [(Kind.RESUME, 0), (Kind.REVOKE, 4), (Kind.REVOKE, 5)])
            self.assertEqual(sent[0][2], struct.pack('<QQ16s', session.decoder.received, 0, nonce))
            # Out of range acknowledgements are protocol errors.
            with self.assertRaises(ValueError):
                session.acknowledge(2)
            with self.assertRaises(ValueError):
                session.acknowledge(99)
        finally:
            sender.cancel()
            await asyncio.gather(sender, return_exceptions=True)
            session.bindings.finish(session.binding_generation)

    async def test_a_frame_draining_when_the_phone_resumes_is_sent_again(self):
        session = self.session()
        drained = asyncio.Event()
        class SlowWriter(Writer):
            async def drain(self): await drained.wait()
        session.writer = SlowWriter()
        sender = asyncio.create_task(session.send_loop())
        try:
            session.send(Kind.REVOKE)
            for _ in range(10): await asyncio.sleep(0)
            # Frame 1 is written and still draining when the phone's RESUME arrives.
            await session.message(self.phone(Kind.RESUME, 0, struct.pack('<QQ16s', 0, 0, b'n' * 16)))
            session.writer.data.clear()
            drained.set()
            for _ in range(10): await asyncio.sleep(0)
            sent = written_envelopes(session.writer.data)
            self.assertEqual([(k, s) for k, s, _ in sent], [(Kind.RESUME, 0), (Kind.REVOKE, 1)])
        finally:
            sender.cancel()
            await asyncio.gather(sender, return_exceptions=True)
            session.bindings.finish(session.binding_generation)

    async def test_a_full_window_holds_the_sender_until_an_acknowledgement(self):
        session = self.session()
        sender = asyncio.create_task(session.send_loop())
        try:
            with mock.patch.object(broker, 'RESUME_WINDOW_MESSAGES', 2):
                for _ in range(3): session.send(Kind.REVOKE)
                await self.drained(session)
                self.assertEqual([s for s, _ in session.retained], [1, 2])
                self.assertEqual(session.pending_count, 1)
                session.acknowledge(1)
                await self.drained(session)
                self.assertEqual([s for s, _ in session.retained], [2, 3])
                self.assertEqual(session.pending_count, 0)
        finally:
            sender.cancel()
            await asyncio.gather(sender, return_exceptions=True)
            session.bindings.finish(session.binding_generation)

    async def test_acknowledges_the_phone_after_a_delay_and_skips_what_it_sends_again(self):
        session = self.session()
        sender = asyncio.create_task(session.send_loop())
        try:
            delivered = []
            async def deliver(frame): delivered.append(frame)
            with mock.patch.object(broker, 'ACK_DELAY', 0.01):
                frames = encode(self.phone(Kind.REVOKED, 1)) + encode(self.phone(Kind.REVOKED, 2))
                got = []
                session.decoder.feed(frames, got.append)
                for frame in got: session.received_sequenced(64)
                await asyncio.sleep(0.05)
                sent = written_envelopes(session.writer.data)
                self.assertEqual([(k, s, p) for k, s, p in sent], [(Kind.ACK, 0, struct.pack('<Q', 2))])
                # The phone sends 2 again after a splice: skipped, 3 delivered.
                got.clear()
                session.decoder.feed(encode(self.phone(Kind.REVOKED, 2)) + encode(self.phone(Kind.REVOKED, 3)), got.append)
                self.assertEqual([f.sequence for f in got], [3])
        finally:
            sender.cancel()
            await asyncio.gather(sender, return_exceptions=True)
            session.bindings.finish(session.binding_generation)

    async def test_resume_controls_are_refused_without_the_feature(self):
        session = broker.Session(None, self.executor, 1, None, Writer(), indexed=True, features={'completion-feed'})
        try:
            with self.assertRaises(ValueError):
                await session.message(self.phone(Kind.ACK, 0, struct.pack('<Q', 0)))
        finally:
            session.bindings.finish(session.binding_generation)


class ExecutorSuspendTests(unittest.IsolatedAsyncioTestCase):
    """Executor suspension (docs/gpu-live.md, "Suspending an executor") on the broker's side."""
    executor = b'a' * 16

    def phone(self, kind, sequence, payload=b''):
        return Envelope(kind, self.executor, 1, 0, 0, sequence, payload)

    async def test_suspend_holds_guest_reads_quiesces_after_reads_in_flight_and_resumes(self):
        session = broker.Session(None, self.executor, 1, None, Writer(), indexed=True,
                                 features={'executor-resume'})
        sender = asyncio.create_task(session.send_loop())
        try:
            # A guest read already past the gate when the phone suspends.
            await session.guest_read()
            await session.message(self.phone(Kind.EXECUTOR_SUSPEND, 1))
            for _ in range(10): await asyncio.sleep(0)
            self.assertFalse(session.guest_open.is_set())
            self.assertNotIn(Kind.QUIESCE, [k for k, _, _ in written_envelopes(session.writer.data)])
            session.send(Kind.REVOKE)  # what that read sends goes before QUIESCE
            session.read_done()
            for _ in range(10): await asyncio.sleep(0)
            kinds = [k for k, _, _ in written_envelopes(session.writer.data) if k != Kind.ACK]
            self.assertEqual(kinds, [Kind.REVOKE, Kind.QUIESCE])
            # A new guest read waits until the phone resumes.
            waiting = asyncio.create_task(session.guest_read())
            for _ in range(10): await asyncio.sleep(0)
            self.assertFalse(waiting.done())
            await session.message(self.phone(Kind.QUIESCED, 2))
            await session.message(self.phone(Kind.EXECUTOR_RESUME, 3, struct.pack('<II', 0, 0)))
            await asyncio.wait_for(waiting, 1)
            session.read_done()
            self.assertFalse(session.suspended)
            with self.assertRaises(ValueError):
                await session.message(self.phone(Kind.EXECUTOR_RESUME, 4, struct.pack('<II', 0, 0)))
        finally:
            sender.cancel()
            await asyncio.gather(sender, return_exceptions=True)
            session.bindings.finish(session.binding_generation)

    async def test_waits_for_the_phone_do_not_run_out_while_it_is_suspended(self):
        session = broker.Session(None, self.executor, 1, None, Writer(), indexed=True, features={'executor-resume'})
        try:
            answer = asyncio.Event()
            # A resumable session waits as long as the host can hold the phone's transport.
            with mock.patch.object(broker, 'RESUME_HOLD_SECONDS', 0.3):
                started = asyncio.get_running_loop().time()
                with self.assertRaises(asyncio.TimeoutError):
                    await session.phone_answer(answer, 0.05)
                self.assertGreaterEqual(asyncio.get_running_loop().time() - started, 0.25)
            session.suspended = True
            session.guest_open.clear()
            hold = mock.patch.object(broker, 'RESUME_HOLD_SECONDS', 0.2); hold.start(); self.addCleanup(hold.stop)
            waiting = asyncio.create_task(session.phone_answer(answer, 0.2))
            await asyncio.sleep(0.5)  # longer than the timeout, but suspended
            self.assertFalse(waiting.done())
            session.suspended = False
            session.guest_open.set()
            with self.assertRaises(asyncio.TimeoutError):
                await asyncio.wait_for(waiting, 2)
            # Answered while suspended: returns at once.
            session.suspended = True
            session.guest_open.clear()
            waiting = asyncio.create_task(session.phone_answer(answer, 0.2))
            await asyncio.sleep(0.05)
            answer.set()
            await asyncio.wait_for(waiting, 1)
        finally:
            session.bindings.finish(session.binding_generation)

    async def test_suspension_controls_need_executor_resume(self):
        session = broker.Session(None, self.executor, 1, None, Writer(), indexed=True, features=set())
        try:
            with self.assertRaises(ValueError):
                await session.message(self.phone(Kind.QUIESCED, 1))
        finally:
            session.bindings.finish(session.binding_generation)


class PhonePriorityTests(unittest.IsolatedAsyncioTestCase):
    """Presentation controls go to the phone ahead of queued DATA (docs/gpu-live.md, "Priority
    toward the phone")."""
    executor = b'a' * 16

    @staticmethod
    def surface(window):
        return b's' * 16 + b't' * 16 + struct.pack('<Q', window)

    def cancel(self, acquire):
        """A SWAPCHAIN_CANCEL_ACQUIRE payload, a priority control."""
        return self.surface(1) + struct.pack('<QQ', 7, acquire)

    def session(self, **kwargs):
        return broker.Session(None, self.executor, 1, None, Writer(), **kwargs)

    @staticmethod
    def taken(session):
        frames = []
        while not session.pending.empty():
            frames.append(session.pending.get_nowait()[0])
        return frames

    def phone_receives(self, frames):
        """The envelopes the phone's decoder accepts from these frames, in order."""
        decoder, envelopes = Decoder(self.executor, 1), []
        for frame in frames:
            decoder.feed(frame[{126: 4, 127: 10}.get(frame[1] & 127, 2):], envelopes.append)
        return [(e.kind, e.sequence, e.stream, e.payload) for e in envelopes]

    async def test_controls_overtake_data_and_each_lane_keeps_its_order(self):
        session = self.session()
        try:
            session.send(Kind.DATA, 1, 1, b'a1')
            session.send(Kind.DATA, 1, 2, b'b1')
            session.send(Kind.SWAPCHAIN_CANCEL_ACQUIRE, 1, payload=self.cancel(1), priority=True)
            session.send(Kind.DATA, 1, 1, b'a2')
            session.send(Kind.SWAPCHAIN_CANCEL_ACQUIRE, 1, payload=self.cancel(2), priority=True)
            self.assertEqual(session.sequence, 1)  # sequences are given as frames leave
            got = self.phone_receives(self.taken(session))
            self.assertEqual(got, [(Kind.SWAPCHAIN_CANCEL_ACQUIRE, 1, 0, self.cancel(1)),
                                   (Kind.SWAPCHAIN_CANCEL_ACQUIRE, 2, 0, self.cancel(2)),
                                   (Kind.DATA, 3, 1, b'a1'), (Kind.DATA, 4, 2, b'b1'),
                                   (Kind.DATA, 5, 1, b'a2')])
            self.assertEqual((session.pending_count, session.sequence), (5, 6))
        finally:
            session.bindings.finish(session.binding_generation)

    async def test_only_acquires_and_presents_take_the_control_lane(self):
        session = self.session()
        try:
            with self.assertRaises(ValueError):
                session.send(Kind.SURFACE_RETIRE, 1, payload=self.surface(1), priority=True)
            session.send(Kind.DATA, 1, 1, b'a1')
            # Surface controls the broker or a process sends without priority keep their place.
            session.send(Kind.SURFACE_RETIRE, 1, payload=self.surface(1))
            session.send(Kind.SWAPCHAIN_CANCEL_ACQUIRE, 1, payload=self.cancel(1))
            session.send(Kind.SWAPCHAIN_CANCEL_ACQUIRE, 1, payload=self.cancel(2), priority=True)
            got = [(kind, payload) for kind, _, _, payload in self.phone_receives(self.taken(session))]
            self.assertEqual(got, [(Kind.DATA, b'a1'), (Kind.SURFACE_RETIRE, self.surface(1)),
                                   (Kind.SWAPCHAIN_CANCEL_ACQUIRE, self.cancel(1)),
                                   (Kind.SWAPCHAIN_CANCEL_ACQUIRE, self.cancel(2))])
        finally:
            session.bindings.finish(session.binding_generation)

    async def test_a_control_never_overtakes_a_queued_frame_that_is_not_data(self):
        session = self.session()
        try:
            session.send(Kind.DATA, 1, 1, b'a1')
            session.send(Kind.FIN, 1, 1)
            session.send(Kind.DATA, 1, 2, b'b1')
            session.send(Kind.STREAM_OPEN, 1, 3)
            session.send(Kind.SWAPCHAIN_CANCEL_ACQUIRE, 1, payload=self.cancel(1), priority=True)
            session.send(Kind.DATA, 1, 3, b'c1')
            session.send(Kind.PROCESS_STOP, 1)
            session.send(Kind.SWAPCHAIN_CANCEL_ACQUIRE, 1, payload=self.cancel(2), priority=True)
            got = [(kind, stream, payload) for kind, _, stream, payload in self.phone_receives(self.taken(session))]
            self.assertEqual(got, [(Kind.DATA, 1, b'a1'), (Kind.FIN, 1, b''), (Kind.DATA, 2, b'b1'),
                                   (Kind.STREAM_OPEN, 3, b''), (Kind.SWAPCHAIN_CANCEL_ACQUIRE, 0, self.cancel(1)),
                                   (Kind.DATA, 3, b'c1'), (Kind.PROCESS_STOP, 0, b''),
                                   (Kind.SWAPCHAIN_CANCEL_ACQUIRE, 0, self.cancel(2))])
        finally:
            session.bindings.finish(session.binding_generation)

    async def test_a_pong_overtakes_data_and_a_close_follows_everything(self):
        session = self.session()
        try:
            session.send(Kind.DATA, 1, 1, b'a1')
            session.enqueue_frame(broker.server_frame(10, b'ping'), control=True)
            session.enqueue_frame(broker.server_frame(8, struct.pack('!H', 1000)))
            session.send(Kind.SWAPCHAIN_CANCEL_ACQUIRE, 1, payload=self.cancel(1), priority=True)
            frames = self.taken(session)
            self.assertEqual([frame[0] & 15 for frame in frames], [10, 2, 8, 2])
            self.assertEqual(frames[0], broker.server_frame(10, b'ping'))
        finally:
            session.bindings.finish(session.binding_generation)

    @unittest.skipUnless(live_zstd.available(), 'libzstd 1.5 is not installed')
    async def test_zstd_records_continue_the_stream_in_the_order_they_leave(self):
        session = self.session(indexed=True, features={'zstd-stream'})
        try:
            await session.message(Envelope(Kind.SESSION_READY, self.executor, 1, 0, 0, 1, broker.HELLO_V4))
            config, _ = session.pending.get_nowait()
            await session.message(Envelope(Kind.TRANSPORT_READY, self.executor, 1, 0, 0, 2, zstd_stream_config(26)))
            payloads = [b'abc' * 5000, os.urandom(65536), b'abc' * 5000]
            session.send(Kind.DATA, 1, 1, payloads[0])
            session.send(Kind.DATA, 1, 2, payloads[1])
            session.send(Kind.SWAPCHAIN_CANCEL_ACQUIRE, 1, payload=self.cancel(1), priority=True)
            session.send(Kind.DATA, 1, 1, payloads[2])
            inflater, parser, envelopes = StreamDecompressor(26), Decoder(self.executor, 1), []
            parser.feed(config[2:], lambda _: None)
            while not session.pending.empty():
                wire, charge = session.pending.get_nowait()
                self.assertGreaterEqual(charge, len(wire))
                self.assertLessEqual(charge, broker.DATA_CREDIT_BYTES)
                message = wire[{126: 4, 127: 10}.get(wire[1] & 127, 2):]
                if message[:4] == b'CGLZ': message = inflater.decompress(message)
                parser.feed(message, envelopes.append)
            self.assertEqual([(e.kind, e.sequence, e.payload) for e in envelopes],
                             [(Kind.SWAPCHAIN_CANCEL_ACQUIRE, 2, self.cancel(1)), (Kind.DATA, 3, payloads[0]),
                              (Kind.DATA, 4, payloads[1]), (Kind.DATA, 5, payloads[2])])
        finally:
            session.bindings.finish(session.binding_generation)

    async def test_a_control_queued_while_the_window_is_full_is_written_first(self):
        session = self.session(indexed=True, features={'executor-resume', 'completion-feed'})
        sender = asyncio.create_task(session.send_loop())
        async def drained():
            for _ in range(20): await asyncio.sleep(0)
        try:
            with mock.patch.object(broker, 'RESUME_WINDOW_MESSAGES', 1):
                session.send(Kind.REVOKE)
                await drained()
                session.send(Kind.DATA, 1, 1, b'x')
                session.send(Kind.SWAPCHAIN_CANCEL_ACQUIRE, 1, payload=self.cancel(1), priority=True)
                await drained()
                self.assertEqual([s for s, _ in session.retained], [1])
                session.acknowledge(1)
                await drained()
                session.acknowledge(2)
                await drained()
            sent = written_envelopes(session.writer.data)
            self.assertEqual([(k, s) for k, s, _ in sent], [(Kind.REVOKE, 1), (Kind.SWAPCHAIN_CANCEL_ACQUIRE, 2), (Kind.DATA, 3)])
            self.assertEqual([s for s, _ in session.retained], [3])
            self.assertEqual(session.retained[0][1], session.writer.data[-len(session.retained[0][1]):])
        finally:
            sender.cancel()
            await asyncio.gather(sender, return_exceptions=True)
            session.bindings.finish(session.binding_generation)
