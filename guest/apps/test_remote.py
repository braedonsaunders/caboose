import json
import os
import socket
import struct
import tempfile
import unittest

import remote


class Transport(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = os.path.join(self.directory.name, 'bridge.sock')
        self.server = remote.BridgeServer(self.path, lambda request: {'ok': True, 'value': request})
        self.addCleanup(self.server.close)

    def connect(self):
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(3)
        conn.connect(self.path)
        self.addCleanup(conn.close)
        return conn

    def test_framing_and_permissions(self):
        self.assertEqual(os.stat(self.path).st_mode & 0o777, 0o600)
        conn = self.connect()
        body = json.dumps({'method': 'files.read'}).encode()
        for b in struct.pack('<I', len(body)) + body:
            conn.sendall(bytes([b]))
        size, = struct.unpack('<I', remote.read_exact(conn, 4))
        self.assertEqual(json.loads(remote.read_exact(conn, size)), {'ok': True, 'value': {'method': 'files.read'}})

    def test_oversize_is_closed(self):
        conn = self.connect()
        conn.sendall(struct.pack('<I', remote.MAX_MESSAGE + 1))
        self.assertEqual(conn.recv(1), b'')

    def test_collision_does_not_unlink_existing_socket(self):
        with self.assertRaises(OSError):
            remote.BridgeServer(self.path, lambda _: None)
        self.assertTrue(os.path.exists(self.path))
        self.connect()

    def test_close_unlinks_and_closes_clients(self):
        conn = self.connect()
        self.server.close()
        self.assertFalse(os.path.exists(self.path))
        # A connection still in the accept backlog is reset when its listener
        # closes on Linux; an accepted connection observes orderly shutdown.
        try:
            self.assertEqual(conn.recv(1), b'')
        except ConnectionResetError:
            pass


class Grants(unittest.TestCase):
    def test_takeover_and_out_of_order_documents_reject_stale_requests(self):
        gate = remote.GrantGate()
        first, second = 'a' * 32, 'b' * 32
        old, current = 'c' * 32, 'd' * 32
        self.assertTrue(gate.update(first))
        self.assertTrue(gate.opening(first, old, 1))
        gate.commit(old, 1)
        self.assertTrue(gate.opening(first, current, 2))
        gate.commit(current, 2)
        with self.assertRaises(ValueError):
            gate.opening(first, old, 1)
        self.assertTrue(gate.update(second))
        self.assertFalse(gate.matches(first))
        with self.assertRaises(ValueError):
            gate.opening(first, old, 99)
        self.assertTrue(gate.opening(second, current, 0))
        gate.commit(current, 0)
        gate.close_document()
        with self.assertRaises(ValueError):
            gate.opening(second, current, 0)
        self.assertTrue(gate.update(None))
        self.assertFalse(gate.matches(second))


class ChildOwnership(unittest.TestCase):
    def test_old_completion_does_not_forget_replacement(self):
        import runpy
        from pathlib import Path
        runtime = runpy.run_path(str(Path(__file__).with_name('caboose-app')))
        children = runtime['Children']()
        old, new = object(), object()
        children.add('spawn:same', old, 1)
        children.add('spawn:same', new, 2)
        self.assertFalse(children.forget('spawn:same', old))
        self.assertIs(children.get('spawn:same'), new)
        self.assertTrue(children.forget('spawn:same', new))
        self.assertIsNone(children.get('spawn:same'))


class ScriptParity(unittest.TestCase):
    def test_device_uses_the_same_public_api_and_isolated_relay(self):
        from pathlib import Path
        here = Path(__file__).resolve().parent
        resources = here.parents[1] / 'apps/ios/CabooseKit/Sources/CabooseKit/Resources'
        self.assertEqual((here / 'page.js').read_bytes(), (resources / 'AgentAppPage.js').read_bytes())
        self.assertEqual((here / 'world.js').read_bytes(), (resources / 'AgentAppWorld.js').read_bytes())


if __name__ == '__main__':
    unittest.main()
