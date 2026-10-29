#!/usr/bin/env python3
"""Run the actual stale system bus recovery policy against disposable socket paths."""
from pathlib import Path
import os
import socket
import subprocess
import sys
import tempfile

script = Path(__file__).with_name('caboose-session').read_text()
probe = script.split("<<'SYSTEM_BUS'\n", 1)[1].split('\nSYSTEM_BUS\n', 1)[0]
with tempfile.TemporaryDirectory() as directory:
    path, pid = Path(directory) / 'bus', Path(directory) / 'pid'
    code = probe.replace('/run/dbus/system_bus_socket', str(path)).replace('/run/dbus/pid', str(pid))
    def check(expected):
        result = subprocess.run([sys.executable, '-c', code])
        assert result.returncode == expected, (expected, result.returncode)
    check(1)
    with socket.socket(socket.AF_UNIX) as server:
        server.bind(str(path)); server.listen()
        check(0)
        assert path.exists()
    pid.write_text(str(os.getpid()))
    check(2)
    assert path.exists() and pid.exists()
    pid.unlink()
    check(1)
    assert not path.exists()
    path.mkdir()
    check(2)
    assert path.is_dir()
print('System bus recovery: missing, live, active pid, stale, and invalid socket passed')
