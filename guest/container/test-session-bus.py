#!/usr/bin/env python3
"""Exercise the session script's actual socket probe without Docker or a running bus."""
from pathlib import Path
import socket
import subprocess
import sys
import tempfile

script = Path(__file__).with_name("caboose-session").read_text()
probe = script.split("<<'PY'\n", 1)[1].split("\nPY\n", 1)[0]
with tempfile.TemporaryDirectory() as directory:
    path = Path(directory) / "bus"

    def check(expected):
        result = subprocess.run([sys.executable, "-", str(path)], input=probe, text=True)
        assert result.returncode == expected, (expected, result.returncode)

    check(1)  # No bus yet.
    with socket.socket(socket.AF_UNIX) as server:
        server.bind(str(path))
        server.listen()
        check(0)  # A live listener must be preserved.
    check(1)  # The file survives its listener.
    path.unlink()
    path.mkdir()
    check(2)  # An unexpected error must not authorize removal.
print("Session bus probe: four cases passed")
