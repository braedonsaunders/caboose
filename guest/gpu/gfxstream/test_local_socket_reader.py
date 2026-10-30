import asyncio
import tempfile
import unittest
from test_live_broker import broker, Writer


class LocalSocketReaderTests(unittest.IsolatedAsyncioTestCase):
    async def test_idle_sockets_hold_no_credit_and_active_stream_runs(self):
        session = broker.Session(None, b'a' * 16, 1, None, Writer())
        tasks, readers, writers, clients, prefetched = [], [], [], [], []
        received = bytearray()
        done = asyncio.Event()
        expected = bytes(range(256)) * 256 * 20
        async def consume(reader, writer):
            try:
                while True:
                    await reader.wait_readable()
                    credit = await session.reserve_data()
                    try:
                        payload = await reader.read(broker.DATA_READ_BYTES)
                        if not payload: break
                        received.extend(payload)
                        writer.write(b'ok'); await writer.drain()
                        if len(received) == len(expected): done.set()
                    finally: credit.release()
            finally:
                reader.close(); writer.close()
                await writer.wait_closed()
        def connected(stream_reader, writer):
            reader = broker.LocalSocketReader(writer)
            readers.append(reader); writers.append(writer); prefetched.append(stream_reader)
            tasks.append(asyncio.create_task(consume(reader, writer)))
        with tempfile.TemporaryDirectory() as directory:
            server = await asyncio.start_unix_server(connected, path=directory+'/stream')
            try:
                for _ in range(24):
                    clients.append(await asyncio.open_unix_connection(directory+'/stream'))
                await asyncio.sleep(0)
                self.assertEqual((session.reserved_count, session.reserved_bytes), (0, 0))
                # More idle streams than the entire credit budget, then 1.25MiB
                # of real data. No idle-reader timeout is needed to make progress.
                client_reader, client_writer = clients[-1]
                client_writer.write(expected); await client_writer.drain()
                await asyncio.wait_for(done.wait(), 2)
                self.assertEqual(received, expected)
                self.assertTrue(all(not r._buffer for r in prefetched))
                self.assertLessEqual(session.reserved_bytes, broker.DATA_CREDIT_BYTES)
                # Original asyncio transport still owns the opposite direction.
                self.assertEqual(await asyncio.wait_for(client_reader.readexactly(2), 1), b'ok')
            finally:
                for _, writer in clients: writer.close()
                await asyncio.gather(*(w.wait_closed() for _, w in clients), return_exceptions=True)
                for task in tasks: task.cancel()
                await asyncio.gather(*tasks, return_exceptions=True)
                server.close(); await server.wait_closed()
                self.assertTrue(all(r.socket.fileno() == -1 for r in readers))
                self.assertEqual((session.reserved_count, session.reserved_bytes), (0, 0))
                session.bindings.finish(session.binding_generation)

    async def test_hello_has_no_read_ahead_and_eof_is_readable(self):
        accepted = asyncio.get_running_loop().create_future()
        def connected(unused_reader, writer):
            accepted.set_result((broker.LocalSocketReader(writer), writer, unused_reader))
        with tempfile.TemporaryDirectory() as directory:
            server = await asyncio.start_unix_server(connected, path=directory+'/stream')
            client_reader, client_writer = await asyncio.open_unix_connection(directory+'/stream')
            reader, writer, unused_reader = await accepted
            try:
                client_writer.write(broker.HELLO + b'payload'); await client_writer.drain()
                self.assertEqual(await asyncio.wait_for(reader.readexactly(48), 1), broker.HELLO)
                await asyncio.wait_for(reader.wait_readable(), 1)
                self.assertEqual(await reader.read(7), b'payload')
                self.assertFalse(unused_reader._buffer)
                # Cancellation leaves no loop fd watcher or consumed byte behind.
                waiting = asyncio.create_task(reader.wait_readable()); await asyncio.sleep(0)
                waiting.cancel(); await asyncio.gather(waiting, return_exceptions=True)
                client_writer.write_eof()
                await asyncio.wait_for(reader.wait_readable(), 1)
                self.assertEqual(await reader.read(1), b'')
            finally:
                reader.close(); writer.close(); client_writer.close()
                await asyncio.gather(writer.wait_closed(), client_writer.wait_closed(), return_exceptions=True)
                server.close(); await server.wait_closed()
