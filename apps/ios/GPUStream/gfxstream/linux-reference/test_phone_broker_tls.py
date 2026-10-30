#!/usr/bin/env python3
"""Linux disposable-container loopback acceptance; never run against a live broker."""
import hashlib
import json
import os
from pathlib import Path
import secrets
import select
import shutil
import signal
import socket
import ssl
import subprocess
import sys
import tempfile
import unittest

from phone_broker import auth_record, receive_exact
import time


class TLSBrokerTests(unittest.TestCase):
    def exercise(self, valid):
        with tempfile.TemporaryDirectory(prefix="caboose-broker-") as name:
            root = Path(name)
            key, cert, token_path = (root / part for part in ("key.pem", "cert.pem", "token"))
            if os.environ.get("CABOOSE_TEST_CERT_DIR"):
                source = Path(os.environ["CABOOSE_TEST_CERT_DIR"])
                shutil.copyfile(source / "key.pem", key)
                shutil.copyfile(source / "cert.pem", cert)
            else:
                subprocess.run(["openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256",
                                "-nodes", "-days", "1", "-subj", "/CN=localhost", "-keyout", str(key), "-out", str(cert)],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True, timeout=5)
            key.chmod(0o600)
            token = secrets.token_bytes(32)
            session = secrets.token_bytes(16)
            token_path.write_bytes(token)
            token_path.chmod(0o600)
            cmd = [sys.executable, str(Path(__file__).with_name("phone_broker.py")),
                   "--bind", "127.0.0.1", "--directory", name, "--cert", str(cert), "--key", str(key),
                   "--token", str(token_path), "--session", session.hex(), "--generation", "7", "--seconds", "15"]
            process = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
            try:
                def event():
                    self.assertTrue(select.select([process.stdout], [], [], 5)[0], "missing broker event")
                    return json.loads(process.stdout.readline())
                listening = event()
                self.assertEqual(listening["event"], "listening")
                context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
                context.minimum_version = context.maximum_version = ssl.TLSVersion.TLSv1_3
                context.check_hostname = False
                context.verify_mode = ssl.CERT_NONE
                with socket.create_connection(("127.0.0.1", listening["port"]), timeout=5) as raw:
                    with context.wrap_socket(raw, server_hostname="localhost") as phone:
                        self.assertEqual(hashlib.sha256(phone.getpeercert(binary_form=True)).hexdigest(), listening["certificate_sha256"])
                        sent_token = token if valid else bytes(v ^ 0xff for v in token)
                        phone.sendall(auth_record(session, 7, sent_token))
                        self.assertEqual(phone.recv(1), b"\x00" if valid else b"\x01")
                        if valid:
                            accepted = event()
                            self.assertEqual(accepted["event"], "authenticated")
                            with socket.socket(socket.AF_UNIX) as guest:
                                guest.settimeout(5)
                                guest.connect(accepted["guest_socket"])
                                request = b"real byte transport\x00\xff" * 4000
                                reply = bytes(range(256)) * 300
                                guest.sendall(request)
                                self.assertEqual(receive_exact(phone, len(request), time.monotonic() + 5), request)
                                for offset in range(0, len(reply), 1021):
                                    phone.sendall(reply[offset:offset + 1021])
                                self.assertEqual(receive_exact(guest, len(reply), time.monotonic() + 5), reply)
                                guest.shutdown(socket.SHUT_WR)
                                completed = event()
                                self.assertEqual(completed, {"event": "finished", "guest_bytes": len(request), "phone_bytes": len(reply)})
                        else:
                            self.assertEqual(event(), {"event": "failed", "error_type": "PermissionError"})
                code = process.wait(timeout=5)
                self.assertEqual(code, 0 if valid else 1)
                stdout, stderr = process.communicate(timeout=1)
                self.assertEqual(stderr, b"")
                self.assertNotIn(token.hex().encode(), stdout)
                self.assertFalse((root / "guest.sock").exists())
            finally:
                if process.poll() is None:
                    os.killpg(process.pid, signal.SIGTERM)
                    try:
                        process.wait(timeout=2)
                    except subprocess.TimeoutExpired:
                        os.killpg(process.pid, signal.SIGKILL)
                        process.wait(timeout=2)
                process.stdout.close()
                process.stderr.close()

    def test_valid_identity_and_duplex(self):
        self.exercise(True)

    def test_wrong_token_rejected_before_unix_socket(self):
        self.exercise(False)


if __name__ == "__main__":
    unittest.main()
