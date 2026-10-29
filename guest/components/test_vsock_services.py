"""Exercise the relay using sockets without requiring a vsock-capable kernel."""
import asyncio
import importlib.util
from pathlib import Path
import socket
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('vsock_services', Path(__file__).with_name('caboose-vsock-services.py'))
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)


class RelayTest(unittest.IsolatedAsyncioTestCase):
    async def test_relay_forwards_and_closes_both_ends(self):
        async def echo(reader, writer):
            writer.write(await reader.read(32))
            await writer.drain()
            writer.close()
            await writer.wait_closed()
        server = await asyncio.start_server(echo, '127.0.0.1', 0)
        port = server.sockets[0].getsockname()[1]
        host, guest = socket.socketpair()
        host.setblocking(False)
        guest.setblocking(False)
        task = asyncio.create_task(bridge.relay(guest, port))
        loop = asyncio.get_running_loop()
        try:
            await loop.sock_sendall(host, b'hello')
            self.assertEqual(await asyncio.wait_for(loop.sock_recv(host, 32), 2), b'hello')
            await asyncio.wait_for(task, 2)
            self.assertEqual(await asyncio.wait_for(loop.sock_recv(host, 32), 2), b'')
        finally:
            task.cancel()
            await asyncio.gather(task, return_exceptions=True)
            host.close()
            server.close()
            await server.wait_closed()

    async def test_rejects_non_host_and_connections_over_the_limit(self):
        class Client:
            closed = False
            def close(self):
                self.closed = True
        clients = [Client(), Client()]
        class Loop:
            async def sock_accept(self, _listener):
                if not clients_left:
                    raise asyncio.CancelledError()
                client = clients_left.pop(0)
                return client, (3 if client is clients[0] else bridge.HOST_CID, 42)
        clients_left = clients.copy()
        with patch.object(bridge.asyncio, 'get_running_loop', return_value=Loop()):
            with self.assertRaises(asyncio.CancelledError):
                await bridge.serve(object(), 14700, set(range(bridge.MAX_CONNECTIONS)))
        self.assertTrue(all(client.closed for client in clients))

    async def test_missing_service_closes_client(self):
        server = await asyncio.start_server(lambda *_: None, '127.0.0.1', 0)
        port = server.sockets[0].getsockname()[1]
        server.close()
        await server.wait_closed()
        host, guest = socket.socketpair()
        host.setblocking(False)
        guest.setblocking(False)
        try:
            await asyncio.wait_for(bridge.relay(guest, port), 2)
            self.assertEqual(await asyncio.get_running_loop().sock_recv(host, 1), b'')
        finally:
            host.close()

if __name__ == '__main__':
    unittest.main()
