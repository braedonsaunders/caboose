#!/usr/bin/env python3
"""Hold migration locks until an appliance process group is known to be gone."""
import ctypes
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

from migration_transaction import atomic_json


def members(group):
    """Return live members of this PID namespace's group, excluding ourselves."""
    result = []
    for entry in Path('/proc').iterdir():
        if not entry.name.isdecimal() or int(entry.name) == os.getpid():
            continue
        try:
            text = (entry / 'stat').read_text()
            fields = text[text.rfind(') ') + 2:].split()
            if int(fields[2]) == group and fields[0] != 'Z':
                result.append(int(entry.name))
        except FileNotFoundError:
            continue
        except (PermissionError, IndexError, ValueError) as error:
            raise RuntimeError(f'Cannot inspect appliance process {entry.name}') from error
    return result


def references(paths, excluded=()):
    """Find processes retaining or intending to open the private appliance files."""
    values = [str(path) for path in paths]
    found = set()
    for entry in Path('/proc').iterdir():
        if not entry.name.isdecimal() or int(entry.name) in excluded:
            continue
        try:
            cmd = (entry / 'cmdline').read_bytes()
            if any(os.fsencode(path) in cmd for path in values):
                found.add(int(entry.name))
            for fd in (entry / 'fd').iterdir():
                try:
                    target = os.readlink(fd)
                    if any(target == path or target.startswith(path + '/') or target == path + ' (deleted)' for path in values):
                        found.add(int(entry.name))
                except FileNotFoundError:
                    continue
        except FileNotFoundError:
            continue
        except PermissionError as error:
            raise RuntimeError(f'Cannot inspect appliance process {entry.name}') from error
    return found


def descendants():
    """Find live descendants, including orphans reparented to this subreaper."""
    table = {}
    for entry in Path('/proc').iterdir():
        if not entry.name.isdecimal():
            continue
        try:
            text = (entry / 'stat').read_text()
            fields = text[text.rfind(') ') + 2:].split()
            if fields[0] != 'Z':
                table[int(entry.name)] = int(fields[1])
        except FileNotFoundError:
            continue
        except (PermissionError, IndexError, ValueError) as error:
            raise RuntimeError(f'Cannot inspect appliance descendant {entry.name}') from error
    owned = {os.getpid()}
    while True:
        more = {pid for pid, parent in table.items() if parent in owned} - owned
        if not more:
            break
        owned.update(more)
    owned.discard(os.getpid())
    return owned


def terminate_members(group):
    for sig in (signal.SIGTERM, signal.SIGKILL):
        for pid in set(members(group)) | descendants():
            try:
                # pidfd prevents signalling a different process if a PID is reused.
                fd = os.pidfd_open(pid)
                try:
                    signal.pidfd_send_signal(fd, sig)
                finally:
                    os.close(fd)
            except ProcessLookupError:
                pass
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            if not members(group) and not descendants():
                return
            time.sleep(.1)
    raise RuntimeError('Appliance process group did not exit')


def main():
    journal = Path(sys.argv[1])
    computer = sys.argv[2]
    timeout = int(sys.argv[3])
    size_limit = int(sys.argv[4])
    appliance_dir = Path(sys.argv[5]).resolve(strict=True)
    parent = int(sys.argv[6])
    command = sys.argv[7:]
    if not command:
        raise ValueError('Missing appliance command')
    if parent <= 1 or os.getppid() != parent:
        raise RuntimeError('Migration parent exited before appliance launch')
    record = json.loads(journal.read_text())
    if (record.get('version') != 1 or record.get('operation') != 'prepare' or
        record.get('computer') != computer or record.get('phase') not in ('reserved', 'idle')):
        raise ValueError('Invalid preparation journal')
    # Reparent orphaned guestfish/QEMU descendants here, even if a child
    # changes process group, so cleanup can identify and reap the owned tree.
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.prctl(36, 1, 0, 0, 0) != 0:  # PR_SET_CHILD_SUBREAPER
        raise OSError(ctypes.get_errno(), 'Cannot enable appliance subreaper')
    group = os.getpgrp()
    if group != os.getpid():
        raise RuntimeError('Appliance guard must own a private process group')
    disks = [command[i + 1] for i, arg in enumerate(command[:-1]) if arg == 'add-drive']
    if not disks or any(not Path(path).is_absolute() for path in disks):
        raise ValueError('Invalid appliance disk paths')
    record.update(phase='running', boot_id=Path('/proc/sys/kernel/random/boot_id').read_text().strip(),
                  pid_namespace=os.stat('/proc/self/ns/pid').st_ino, process_group=group,
                  appliance_dir=str(appliance_dir), appliance_disks=disks)
    atomic_json(journal, record)
    interrupted = False
    def stop(_signum, _frame):
        nonlocal interrupted
        interrupted = True
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    child = None
    status = 1
    try:
        if os.getppid() != parent:
            raise RuntimeError('Migration parent exited before appliance launch')
        child = subprocess.Popen(['/usr/bin/prlimit', f'--fsize={size_limit}:{size_limit}', '--', *command],
                                 stdin=subprocess.DEVNULL)
        deadline = time.monotonic() + timeout
        while child.poll() is None and not interrupted and time.monotonic() < deadline:
            if os.getppid() != parent:
                interrupted = True
                break
            time.sleep(.1)
        if child.poll() is None:
            print('Migration appliance interrupted or timed out', file=sys.stderr)
        else:
            status = child.returncode
    finally:
        terminate_members(group)
        if child is not None:
            child.wait()
        while True:
            try:
                pid, _ = os.waitpid(-1, os.WNOHANG)
                if pid == 0:
                    break
            except ChildProcessError:
                break
        excluded = (os.getpid(), parent) if os.getppid() == parent else (os.getpid(),)
        if references([appliance_dir, *disks], excluded):
            raise RuntimeError('An unverified process still references the appliance')
    # This durable transition is written only after every owned group member
    # has exited. A crash before it leaves a recovery fence in place.
    record['phase'] = 'idle'
    atomic_json(journal, record)
    return status


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, ValueError, KeyError) as error:
        print(f'Appliance guard failed: {error}', file=sys.stderr)
        raise SystemExit(1)
