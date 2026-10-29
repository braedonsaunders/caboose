#!/usr/bin/env python3
"""Disposable Linux/KVM proof of appliance lock and parent-death cleanup."""
import argparse
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import signal
import shutil
import subprocess
import sys
import tempfile
import time

SRC = Path(__file__).resolve().parents[1] / 'src'
sys.path.insert(0, str(SRC))
from migration_transaction import atomic_json
from migration_appliance_guard import members


def is_live(pid):
    try:
        return Path(f'/proc/{pid}/stat').read_text().split(') ', 1)[1][0] != 'Z'
    except FileNotFoundError:
        return False


def child(root):
    from migration_appliance import _guestfish
    root = Path(root)
    disk = root / 'overlays/.owner.migration-staged.raw'
    work = root / 'migration-images/guard'
    journal = root / 'overlays/owner.migration.json'
    fd = os.open(root / '.host.lock', os.O_RDWR | os.O_CREAT, 0o600)
    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    atomic_json(journal, {'version': 1, 'operation': 'prepare', 'computer': 'owner', 'phase': 'reserved'})
    env = {k: v for k, v in os.environ.items() if not k.startswith(('LIBGUESTFS_', 'LD_'))}
    env.update(LIBGUESTFS_BACKEND='direct', LIBGUESTFS_CACHEDIR=str(work), TMPDIR=str(work))
    args = ['/usr/bin/guestfish', 'add-drive', str(disk), 'readonly:true', 'format:raw', ':',
            'set-network', 'false', ':', 'set-memsize', '1024', ':', 'run', ':',
            'debug', 'sh', 'sleep 300', ':', 'shutdown']
    _guestfish(args, env, work / 'appliance.log', 300, disk.stat().st_size + 1024 ** 3,
               {'journal': journal, 'computer': 'owner', 'fds': (fd,)})


def main():
    if len(sys.argv) == 3 and sys.argv[1] == '--child':
        child(sys.argv[2])
        return
    p = argparse.ArgumentParser()
    p.add_argument('--work', required=True, type=Path)
    p.add_argument('--base', required=True, type=Path, help='golden image, copied before use')
    a = p.parse_args()
    if sys.platform != 'linux' or os.geteuid() != 0:
        p.error('Linux root is required')
    root = Path(tempfile.mkdtemp(prefix='appliance-guard-check-', dir=a.work.resolve(strict=True)))
    print(f'Guard fixture: {root}', flush=True)
    (root / 'overlays').mkdir()
    work = root / 'migration-images/guard'
    work.mkdir(parents=True)
    disk = root / 'overlays/.owner.migration-staged.raw'
    subprocess.run(['/usr/bin/cp', '--reflink=always', '--sparse=auto', '--', str(a.base), str(disk)], check=True)
    parent = subprocess.Popen([sys.executable, __file__, '--child', str(root)], stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL)
    journal = root / 'overlays/owner.migration.json'
    guard_pid = None
    try:
        deadline = time.monotonic() + 180
        while time.monotonic() < deadline:
            if parent.poll() is not None:
                raise RuntimeError('Appliance parent exited before QEMU started')
            try:
                data = json.loads(journal.read_text())
                if data.get('phase') == 'running':
                    group = data['process_group']
                    for pid in members(group):
                        try:
                            executable = os.readlink(f'/proc/{pid}/exe')
                            if 'qemu-system-' in executable:
                                guard_pid = group
                                break
                        except FileNotFoundError:
                            pass
                if guard_pid:
                    break
            except FileNotFoundError:
                pass
            time.sleep(.1)
        if not guard_pid:
            raise RuntimeError('Timed out waiting for guarded QEMU')
        # Freeze only our guard so QEMU remains alive while its parent dies.
        os.kill(guard_pid, signal.SIGSTOP)
        parent.kill()
        parent.wait()
        with (root / '.host.lock').open('r+') as contender:
            try:
                fcntl.flock(contender, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                pass
            else:
                raise AssertionError('Guard did not retain host lock after parent death')
        if not members(guard_pid):
            raise AssertionError('QEMU exited before the parent-death check')
        # Recovery must refuse while the real appliance group is alive.
        spec = importlib.util.spec_from_file_location('migration_cli', SRC.parent / 'scripts/migrate-disk.py')
        cli = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cli)
        try:
            cli.prepare_quiescent(cli.Transaction(root, 'owner'))
        except RuntimeError as error:
            if 'still running' not in str(error):
                raise
        else:
            raise AssertionError('Recovery accepted a live appliance')
        os.kill(guard_pid, signal.SIGCONT)
        deadline = time.monotonic() + 40
        while time.monotonic() < deadline and is_live(guard_pid):
            time.sleep(.1)
        if is_live(guard_pid) or members(guard_pid):
            raise AssertionError('Guard or appliance survived parent-death cleanup')
        if json.loads(journal.read_text()).get('phase') != 'idle':
            raise AssertionError('Guard did not durably record verified exit')
        with (root / '.host.lock').open('r+') as contender:
            fcntl.flock(contender, fcntl.LOCK_EX | fcntl.LOCK_NB)
        print('QEMU was grouped; guard held the lock after parent death and cleaned up')
    finally:
        if parent.poll() is None:
            parent.terminate()
            try:
                parent.wait(timeout=10)
            except subprocess.TimeoutExpired:
                parent.kill(); parent.wait()
        if guard_pid is None and journal.exists():
            record = json.loads(journal.read_text())
            if record.get('phase') == 'running' and Path(record.get('appliance_dir', '/')).is_relative_to(root):
                guard_pid = record.get('process_group')
        if guard_pid and is_live(guard_pid):
            try:
                os.kill(guard_pid, signal.SIGCONT)
                os.kill(guard_pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline and is_live(guard_pid):
                time.sleep(.1)
            if is_live(guard_pid):
                os.killpg(guard_pid, signal.SIGKILL)
                raise RuntimeError('Guard required forced termination; fixture retained')
        if guard_pid and members(guard_pid):
            raise RuntimeError('Appliance group remains; fixture retained')
    shutil.rmtree(root)

if __name__ == '__main__':
    main()
