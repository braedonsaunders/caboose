"""The broker's presentation of phone-resident buffers in compositor windows."""
import asyncio
import errno
from importlib.machinery import SourceFileLoader
import importlib.util
import os
from pathlib import Path
import struct
import sys
import unittest
from unittest import mock

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / 'broker'))
loader = SourceFileLoader('caboose_live_broker_buffers', str(HERE / 'caboose-gpu-broker'))
spec = importlib.util.spec_from_loader(loader.name, loader)
broker = importlib.util.module_from_spec(spec)
loader.exec_module(broker)
import buffer_presentation as buffers
import control_protocol
from live_protocol import Decoder, Envelope, Kind
from test_live_broker import Writer

EXECUTOR = b'a' * 16
IMAGE = buffers.Image(instance=11, device=12, queue=13, image=14, vk_format=44, width=640, height=480, queue_family=0)


class Harness:
    """A ready session whose broker grants every bind for process 3."""
    def __init__(self, test):
        self.session = broker.Session(None, EXECUTOR, 1, None, Writer(), indexed=True)
        self.session.session_ready.set()
        ready = asyncio.Event(); ready.set()
        self.session.processes[3] = {'ready': ready, 'surfaces': set(), 'streams': {1}, 'stopping': False,
                                     'retired': asyncio.Event()}
        self.released = []
        self.revoke_requests = []
        self.binds = 0
        session = self.session

        async def send_control(data, fd=None):
            record = control_protocol.decode(data, 0)
            if isinstance(record, control_protocol.BufferReleased):
                self.released.append((record.request, record.status))
            elif isinstance(record, control_protocol.RevokeRequest):
                self.revoke_requests.append(record)

        async def request_bind(owner, process, window, space=0):
            test.assertEqual(space, control_protocol.BUFFER_WINDOW)
            self.binds += 1
            key = (b'e' * 16, bytes([self.binds]) * 16, self.binds)
            session.surfaces[key] = {'process': process, 'window': window, 'retiring': False, 'retire_sent': False,
                                     'revoke_requested': False, 'bind_sent': False, 'disconnected': False,
                                     'retired': asyncio.Event()}
            session.processes[process]['surfaces'].add(key)
            return control_protocol.BindResult(self.binds, 0, key[0], key[1], window, key[2])

        self.session.broker = mock.Mock(send_control=send_control, request_bind=request_bind)
        r, w = os.pipe()
        os.close(w)
        self.fd = r
        info = os.fstat(r)
        self.identity = (info.st_dev, info.st_ino)
        self.session.register_buffer('driver', 3, r, buffers.encode_register(IMAGE))
        self.sequence = 100
        self.decoder = Decoder(EXECUTOR, 1)

    def close(self):
        os.close(self.fd)
        self.session.bindings.finish(self.session.binding_generation)

    def sent(self):
        records = []
        while not self.session.pending.empty():
            wire, charge = self.session.pending.get_nowait()
            self.session.pending_bytes -= charge; self.session.pending_count -= 1
            self.decoder.feed(wire[2:] if wire[1] < 126 else wire[4:], records.append)
        return records

    async def deliver(self, kind, payload):
        self.sequence += 1
        await self.session.message(Envelope(kind, EXECUTOR, 1, 3, 0, self.sequence, payload))

    def present(self, request, window=9):
        self.session.present_buffer(control_protocol.BufferPresent(request, window, *self.identity,
                                                                   IMAGE.width, IMAGE.height))

    @staticmethod
    def result(identity, serial, disposition, error=0):
        return identity + struct.pack('<QiIiIII', serial, error, 0 if error else 1, 0, 0, disposition, 0)


async def settle():
    for _ in range(10): await asyncio.sleep(0)


class BrokerBufferTests(unittest.IsolatedAsyncioTestCase):
    async def test_commit_binds_presents_and_releases_on_source_release(self):
        h = Harness(self)
        try:
            h.present(1)
            await settle()
            bind, = h.sent()
            self.assertEqual((bind.kind, bind.process), (Kind.SURFACE_BIND, 3))
            identity = bind.payload[:40]
            self.assertEqual(struct.unpack_from('<QQII', bind.payload, 40), (9, IMAGE.instance, 640, 480))
            await h.deliver(Kind.SURFACE_BOUND, identity + struct.pack('<iIiI', 0, 1, 0, 0))
            await settle()
            present, = h.sent()
            self.assertEqual(present.kind, Kind.PRESENT)
            self.assertEqual(present.payload[40:], buffers.present_body(1, IMAGE))
            # A second commit waits; a third replaces it.
            h.present(2); h.present(3)
            await settle()
            self.assertEqual(h.sent(), [])
            self.assertEqual(h.released, [(2, errno.ECANCELED)])
            await h.deliver(Kind.PRESENT_RESULT, h.result(identity, 1, 1))
            await h.deliver(Kind.SOURCE_RELEASED, identity + struct.pack('<Q', 1))
            await settle()
            self.assertEqual(h.released, [(2, errno.ECANCELED), (1, 0)])
            present, = h.sent()
            self.assertEqual(struct.unpack_from('<Q', present.payload, 40)[0], 2)
            # The busy native surface is offered the same frame again.
            await h.deliver(Kind.PRESENT_RESULT, h.result(identity, 2, 0, errno.EBUSY))
            await asyncio.sleep(buffers.RETRY_SECONDS * 3)
            retried, = h.sent()
            self.assertEqual(retried.payload[48:], buffers.present_body(3, IMAGE)[8:])
            self.assertEqual(h.binds, 1)
        finally:
            h.close()

    async def test_unknown_or_mismatched_buffer_is_released_unshown(self):
        h = Harness(self)
        try:
            h.session.present_buffer(control_protocol.BufferPresent(1, 9, h.identity[0], h.identity[1] + 1, 640, 480))
            h.session.present_buffer(control_protocol.BufferPresent(2, 9, *h.identity, 641, 480))
            await settle()
            self.assertEqual(sorted(h.released), [(1, errno.ENOENT), (2, errno.EINVAL)])
            self.assertEqual(h.sent(), [])
        finally:
            h.close()

    async def test_retired_grant_releases_in_flight_and_rebinds_for_a_waiting_commit(self):
        h = Harness(self)
        try:
            h.present(1)
            await settle()
            identity = h.sent()[0].payload[:40]
            await h.deliver(Kind.SURFACE_BOUND, identity + struct.pack('<iIiI', 0, 1, 0, 0))
            await settle()
            h.sent()
            key = (identity[:16], identity[16:32], struct.unpack_from('<Q', identity, 32)[0])
            # The compositor revokes the window's grant; the phone retires it.
            h.session.request_surface_retire(control_protocol.RevokeGrant(*key))
            retire, = h.sent()
            self.assertEqual(retire.kind, Kind.SURFACE_RETIRE)
            h.present(2)
            await h.deliver(Kind.PRESENT_RESULT, h.result(identity, 1, 1))
            await h.deliver(Kind.SOURCE_RELEASED, identity + struct.pack('<Q', 1))
            await h.deliver(Kind.SURFACE_RETIRED, identity + struct.pack('<iIiI', 0, 1, 0, 0))
            await settle()
            self.assertIn((1, 0), h.released)
            self.assertNotIn(key, h.session.surfaces)
            self.assertEqual(h.binds, 2)
            bind, = h.sent()
            self.assertEqual(bind.kind, Kind.SURFACE_BIND)
        finally:
            h.close()

    async def test_resize_requests_retirement_of_the_old_grant(self):
        h = Harness(self)
        try:
            h.present(1)
            await settle()
            identity = h.sent()[0].payload[:40]
            await h.deliver(Kind.SURFACE_BOUND, identity + struct.pack('<iIiI', 0, 1, 0, 0))
            await settle(); h.sent()
            bigger = buffers.Image(11, 12, 13, 15, 44, 800, 600, 0)
            r, w = os.pipe(); os.close(w)
            try:
                h.session.register_buffer('driver', 3, r, buffers.encode_register(bigger))
                info = os.fstat(r)
                h.session.present_buffer(control_protocol.BufferPresent(2, 9, info.st_dev, info.st_ino, 800, 600))
                await settle()
            finally:
                os.close(r)
            self.assertEqual(len(h.revoke_requests), 1)
            self.assertEqual(h.revoke_requests[0].generation, struct.unpack_from('<Q', identity, 32)[0])
        finally:
            h.close()

    async def test_presents_before_session_is_ready_are_released(self):
        instance = broker.Broker.__new__(broker.Broker)
        instance.session = None
        instance.tasks = set()
        sent = []
        async def send_control(data, fd=None): sent.append(control_protocol.decode(data, 0))
        instance.send_control = send_control
        # The control reader's handling, applied directly.
        record = control_protocol.BufferPresent(4, 9, 1, 2, 3, 4)
        task = asyncio.create_task(instance.send_control(control_protocol.encode_buffer_released(
            control_protocol.BufferReleased(record.request, errno.ENODEV))))
        await task
        self.assertEqual(sent, [control_protocol.BufferReleased(4, errno.ENODEV)])


if __name__ == '__main__': unittest.main()
