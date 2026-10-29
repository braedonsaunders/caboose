#!/usr/bin/env python3
"""Check host exclusion across exec and parent exit with disposable processes."""
import fcntl
from pathlib import Path
import subprocess
import sys
import tempfile
import time

helper = Path(__file__).resolve().parents[2] / 'src/host-lock.py'
with tempfile.TemporaryDirectory() as directory:
    code = "const {spawn}=require('child_process'); const c=spawn(process.execPath,['-e','setTimeout(()=>{},1500)'],{stdio:['ignore','ignore','ignore',3]}); c.unref()"
    host = subprocess.run([sys.executable, str(helper), directory, 'node', '-e', code], capture_output=True, text=True, timeout=10)
    if host.returncode:
        raise RuntimeError(host.stderr)
    blocked = subprocess.run([sys.executable, str(helper), directory, 'true'], capture_output=True, text=True, timeout=10)
    assert blocked.returncode != 0 and 'locked' in blocked.stderr, blocked.stderr
    with (Path(directory) / '.host.lock').open('r+') as contender:
        deadline = time.monotonic() + 10
        while True:
            try:
                fcntl.flock(contender, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise AssertionError('lock remained after child exit')
                time.sleep(.05)
print('host lock survives host exit until child exits')
