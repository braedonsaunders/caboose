#!/usr/bin/env python3
"""Verify real child daemons retain the host flock after their parent exits.

Run on Linux with an isolated directory, a disposable raw disk, and v54 tools.
This script starts only its own VMM and virtiofsd and stops both before exit.
"""
import argparse
import fcntl
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

SCRIPT = Path(__file__).resolve().parents[1] / 'src/host-lock.py'


def live(pid):
    try:
        state = Path(f'/proc/{pid}/stat').read_text().split(') ', 1)[1][0]
        return state != 'Z'
    except FileNotFoundError:
        return False


def check_child(label, command, work, ready_path=None):
    lockroot = work / label
    lockroot.mkdir(mode=0o700)
    # Same stdio mapping as the host's AppKit launcher: inherited host lock
    # is fd 3 in the daemon. Node exits immediately after the child starts.
    js = '''const {spawn}=require('node:child_process');
const c=spawn(process.argv[1],process.argv.slice(2),{stdio:['ignore','ignore','ignore',3],detached:true});
c.once('error',()=>process.exit(2));
c.once('spawn',()=>{console.log(c.pid);c.unref()});'''
    result = subprocess.run([sys.executable, str(SCRIPT), str(lockroot), 'node', '-e', js, *command],
                            capture_output=True, text=True, timeout=30, check=True)
    pid = int(result.stdout.strip())
    try:
        for _ in range(50):
            if not live(pid) or ready_path is None or ready_path.exists():
                break
            time.sleep(.1)
        time.sleep(2)
        if ready_path is not None and not ready_path.exists():
            raise RuntimeError(f'{label} did not create its socket')
        if not live(pid):
            raise RuntimeError(f'{label} exited before the lock check')
        with (lockroot / '.host.lock').open('r+') as contender:
            try:
                fcntl.flock(contender, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                print(f'{label}: lock survives host exit', flush=True)
            else:
                raise RuntimeError(f'{label} dropped the inherited host lock')
    finally:
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        for _ in range(100):
            if not live(pid):
                break
            time.sleep(.1)
        else:
            os.kill(pid, signal.SIGKILL)
            for _ in range(100):
                if not live(pid):
                    break
                time.sleep(.1)
            else:
                raise RuntimeError(f'{label} did not exit')
    with (lockroot / '.host.lock').open('r+') as contender:
        fcntl.flock(contender, fcntl.LOCK_EX | fcntl.LOCK_NB)
    print(f'{label}: lock released after daemon exit', flush=True)


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--work', required=True, type=Path)
    p.add_argument('--vmm', required=True)
    p.add_argument('--virtiofsd', required=True)
    p.add_argument('--base', required=True, help='golden base.raw; only a reflinked disposable copy is booted')
    p.add_argument('--kernel', required=True)
    p.add_argument('--initrd', required=True)
    a = p.parse_args()
    if sys.platform != 'linux' or os.geteuid() != 0:
        p.error('Linux root is required')
    work = a.work.resolve(strict=True)
    with tempfile.TemporaryDirectory(prefix='inherited-lock-', dir=work) as d:
        stage = Path(d)
        disk = stage / 'fixture.raw'
        subprocess.run(['cp', '--reflink=always', '--sparse=auto', '--', a.base, str(disk)], check=True)
        shared = stage / 'share'
        shared.mkdir()
        socket = stage / 'virtiofs.sock'
        check_child('virtiofsd', [a.virtiofsd, '--socket-path', str(socket), '--shared-dir', str(shared), '--sandbox', 'none'], stage, socket)
        check_child('vmm', [a.vmm, '--kernel', a.kernel, '--initramfs', a.initrd,
                           '--cmdline', 'root=/dev/vda3 rw', '--disk', f'path={disk},image_type=raw',
                           '--cpus', 'boot=1', '--memory', 'size=512M', '--serial', 'off', '--console', 'off'], stage)


if __name__ == '__main__':
    main()
