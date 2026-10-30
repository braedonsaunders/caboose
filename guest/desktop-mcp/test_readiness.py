"""Readiness checks use control identity and TCP listening, never a display handshake."""
import json
import os
import pathlib
import socket
import subprocess
import tempfile
import threading
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / 'display/caboose-display-ready'


class ReadinessTest(unittest.TestCase):
    @unittest.skipIf(os.getuid() == 0, "stand-in uses the invoking non-root user")
    def test_warm_checks_do_not_send_client_hello(self):
        with tempfile.TemporaryDirectory(dir='/tmp') as directory:
            control = socket.socket(socket.AF_UNIX)
            path = directory + '/control.sock'
            control.bind(path)
            control.listen()
            port = socket.socket()
            port.bind(('127.0.0.1', 0))
            port.listen()
            port.settimeout(2)
            requests = []
            def serve():
                for _ in range(2):
                    conn, _ = control.accept()
                    with conn:
                        requests.append(conn.recv(1024))
                        conn.sendall(b'{"ok":true,"windows":[]}\n')
            thread = threading.Thread(target=serve, daemon=True)
            thread.start()
            envfile = pathlib.Path(directory) / 'display.env'
            envfile.write_text(f'CABOOSE_DISPLAY_CONTROL={path}\n')
            try:
                for _ in range(2):
                    subprocess.run(['sh', str(SCRIPT), '1', str(port.getsockname()[1]), str(envfile)], check=True, timeout=3)
                    conn, _ = port.accept()
                    with conn:
                        self.assertEqual(conn.recv(1024), b'')
                thread.join(2)
                self.assertEqual(requests, [b'windows\n', b'windows\n'])
            finally:
                control.close()
                port.close()
