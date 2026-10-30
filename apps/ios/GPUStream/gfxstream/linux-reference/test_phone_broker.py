#!/usr/bin/env python3
"""Socket-pair tests; no TCP listener, Vulkan driver, or device is opened."""
import socket
import tempfile
import threading
import time
import unittest
from pathlib import Path

from phone_broker import auth_record, private_directory, relay, secret_file


class BrokerTests(unittest.TestCase):
    def test_auth_layout_and_invalid_identity(self):
        record = auth_record(bytes(range(16)), 0x0102030405060708, bytes(range(32)))
        self.assertEqual(len(record), 64)
        self.assertEqual(record[:8], b"CBGTLS01")
        self.assertEqual(record[8:24], bytes(range(16)))
        self.assertEqual(record[24:32], bytes(range(1, 9)))
        self.assertEqual(record[32:], bytes(range(32)))
        for session, generation, token in ((bytes(16), 1, bytes(32)), (b"x", 1, bytes(32)),
                                            (b"x" * 16, 0, bytes(32)),
                                            (b"x" * 16, 2**64, bytes(32)),
                                            (b"x" * 16, 1, bytes(31))):
            with self.assertRaises(ValueError):
                auth_record(session, generation, token)

    def test_private_paths(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            root.chmod(0o700)
            private_directory(root)
            token = root / "token"
            token.write_bytes(b"x" * 32)
            token.chmod(0o600)
            self.assertEqual(secret_file(token, 32), b"x" * 32)
            token.chmod(0o644)
            with self.assertRaises(ValueError):
                secret_file(token, 32)
            link = root / "link"
            link.symlink_to(token)
            with self.assertRaises(OSError):
                secret_file(link, 32)
            root.chmod(0o755)
            with self.assertRaises(ValueError):
                private_directory(root)

    def test_bidirectional_fragmentation_and_cleanup(self):
        guest, app = socket.socketpair()
        phone, executor = socket.socketpair()
        sockets = (guest, app, phone, executor)
        for stream in sockets:
            stream.settimeout(3)
        request = bytes(range(256)) * 1025
        response = bytes(reversed(range(256))) * 1027
        results, errors = [], []

        def bridge():
            try:
                results.append(relay(guest, phone, time.monotonic() + 3))
            except Exception as error:
                errors.append(error)

        def gpu_side():
            try:
                received = bytearray()
                while len(received) < len(request):
                    chunk = executor.recv(min(517, len(request) - len(received)))
                    if not chunk:
                        raise ConnectionError("early request EOF")
                    received.extend(chunk)
                self.assertEqual(received, request)
                executor.sendall(response)
                executor.shutdown(socket.SHUT_WR)
            except Exception as error:
                errors.append(error)

        workers = [threading.Thread(target=bridge), threading.Thread(target=gpu_side)]
        try:
            for worker in workers:
                worker.start()
            app.sendall(request)
            received = bytearray()
            while len(received) < len(response):
                chunk = app.recv(min(733, len(response) - len(received)))
                self.assertTrue(chunk)
                received.extend(chunk)
            self.assertEqual(received, response)
        finally:
            for worker in workers:
                worker.join(timeout=4)
            for stream in sockets:
                stream.close()
            for worker in workers:
                worker.join(timeout=1)
                self.assertFalse(worker.is_alive())
        self.assertFalse(errors, errors)
        self.assertEqual(results, [{"guest_bytes": len(request), "phone_bytes": len(response)}])

    def test_deadline_and_byte_budget(self):
        guest, app = socket.socketpair()
        phone, executor = socket.socketpair()
        try:
            with self.assertRaises(TimeoutError):
                relay(guest, phone, time.monotonic() + 0.01)
            app.sendall(b"x" * 33)
            with self.assertRaises(ValueError):
                relay(guest, phone, time.monotonic() + 1, max_bytes=32)
        finally:
            for stream in (guest, app, phone, executor):
                stream.close()


if __name__ == "__main__":
    unittest.main()
