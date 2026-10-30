#!/usr/bin/env python3
"""Exercise private hello rejection and flags/EOF, not Vulkan commands."""
import os
import pathlib
import socket
import subprocess
import sys
import tempfile
import time

receiver, loader = sys.argv[1:]
hello = b'CBGLREF1' + (2).to_bytes(4, 'little') + (0x10).to_bytes(4, 'little') + bytes.fromhex(
    '20d3bb2e30337cabf0febb006ed102ab25ccf6d9ddbfaf624c7e68f9040969c0')
cases = [
    ('legacy v1 rejected', hello[:8] + (1).to_bytes(4, 'little') + bytes(4) + hello[16:], False),
    ('zero mask rejected', hello[:12] + bytes(4) + hello[16:], False),
    ('unknown bit rejected', hello[:12] + (0x30).to_bytes(4, 'little') + hello[16:], False),
    ('fingerprint mismatch rejected', hello[:-1] + bytes([hello[-1] ^ 1]), False),
    ('valid EOF', hello, True),
]
for description, offered, valid in cases:
    with tempfile.TemporaryDirectory(prefix='caboose-receiver-', dir='/tmp') as directory:
        path = pathlib.Path(directory) / 'decoder.sock'
        with tempfile.TemporaryFile() as log:
            process = subprocess.Popen(['timeout', '30', receiver, loader, directory], stdout=log, stderr=log)
            try:
                deadline = time.monotonic() + 20
                while not path.exists() and process.poll() is None and time.monotonic() < deadline:
                    time.sleep(0.05)
                with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
                    client.settimeout(5)
                    client.connect(str(path))
                    client.sendall(offered)
                    reply = b''
                    while len(reply) < len(hello):
                        part = client.recv(len(hello) - len(reply))
                        if not part:
                            break
                        reply += part
                    if valid:
                        assert reply == hello
                        client.sendall(bytes(4))
                        client.shutdown(socket.SHUT_WR)
                    else:
                        assert not reply
                code = process.wait(timeout=30)
                assert code == (0 if valid else 1), code
                assert not path.exists(), 'socket was not cleaned up'
                print(description + ' passed')
            except BaseException:
                process.terminate()
                try:
                    process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
                log.seek(0)
                sys.stderr.buffer.write(log.read())
                raise
