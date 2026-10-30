import asyncio
from importlib.machinery import SourceFileLoader
import importlib.util
from pathlib import Path
import sys
import unittest

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / 'broker'))
loader = SourceFileLoader('caboose_live_broker', str(HERE / 'caboose-gpu-broker'))
spec = importlib.util.spec_from_loader(loader.name, loader)
broker = importlib.util.module_from_spec(spec)
loader.exec_module(broker)
from live_protocol import Decoder, Envelope, Kind


class Writer:
    def __init__(self): self.data = bytearray(); self.eof = False
    def write(self, data): self.data.extend(data)
    async def drain(self): pass
    def write_eof(self): self.eof = True
    def close(self): pass
    async def wait_closed(self): pass


class LiveBrokerTests(unittest.IsolatedAsyncioTestCase):
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

    async def test_unknown_stream_is_rejected(self):
        session = broker.Session(None, b'a' * 16, 1, None, Writer())
        session.session_ready.set()
        with self.assertRaises(ValueError):
            await session.message(Envelope(Kind.DATA, b'a' * 16, 1, 1, 2, 1, b'x'))
        session.bindings.finish(session.binding_generation)


if __name__ == '__main__': unittest.main()
