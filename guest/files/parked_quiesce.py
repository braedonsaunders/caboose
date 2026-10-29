#!/usr/bin/env python3
"""Fail-closed checks and cgroup freezer operations for parked Files.

This module does not establish snapshot authority by itself. The caller must keep
admission fenced, journal recovery on the host, freeze the filesystem, and bind
an independent disk snapshot to the parked memory image.
"""
import os
import errno
import fcntl
import re
import time
from pathlib import Path


class Unsupported(RuntimeError):
    pass


def within(path, root):
    return path == root or path.startswith(root.rstrip('/') + '/')


def check_mounts(mountinfo, home='/home/caboose'):
    """Require home to live on the root ext4 mount, with no nested mounts."""
    mounts = []
    for line in mountinfo.splitlines():
        fields = line.split()
        try:
            sep = fields.index('-')
            mountpoint, filesystem = fields[4], fields[sep + 1]
        except (ValueError, IndexError):
            raise Unsupported('invalid mount information')
        # Escaped mount points are uncommon here and cannot be safely compared as-is.
        if '\\' in mountpoint:
            raise Unsupported('escaped mount point')
        mounts.append((mountpoint, filesystem))
    root = [fs for point, fs in mounts if point == '/']
    if root != ['ext4']:
        raise Unsupported('root is not a single ext4 mount')
    if any(point != '/' and (within(home, point) or within(point, home)) for point, _ in mounts):
        raise Unsupported('home has an unsupported mount')


def check_processes(processes, managed='/caboose-workloads.slice', owner=1000, trusted=()):
    """Reject an owner outside the boundary and any outside shared writable map.

    Each process record is (pid, real_uid, cgroup_path, maps_text). The caller
    must obtain a complete, stable inventory while admission is fenced; inaccessible
    proc entries and races must fail closed.
    """
    trusted = set(trusted)
    for pid, uid, cgroup, maps in processes:
        if pid in trusted:
            continue
        if not cgroup.startswith('/') or '..' in cgroup.split('/'):
            raise Unsupported('invalid process cgroup')
        if within(cgroup, managed):
            continue
        if uid == owner:
            raise Unsupported('owner process outside managed slice')
        for line in maps.splitlines():
            fields = line.split(None, 5)
            if len(fields) < 2 or not re.fullmatch(r'[r-][w-][x-][ps]', fields[1]):
                raise Unsupported('invalid process mapping')
            if fields[1][1] == 'w' and fields[1][3] == 's':
                raise Unsupported('shared writable mapping outside managed slice')


def inventory(proc='/proc'):
    """Read userspace process metadata; any inaccessible or changing entry fails."""
    result = []
    try:
        pids = sorted(int(p.name) for p in Path(proc).iterdir() if p.name.isdecimal())
        for pid in pids:
            base = Path(proc) / str(pid)
            status = (base / 'status').read_text()
            uid = re.search(r'^Uid:\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)', status, re.M)
            groups = (base / 'cgroup').read_text().splitlines()
            unified = [line[3:] for line in groups if line.startswith('0::')]
            if not uid or len(unified) != 1:
                raise Unsupported('process identity or cgroup unavailable')
            maps = (base / 'maps').read_text()
            ids = tuple(map(int, uid.groups()))
            result.append((pid, 1000 if 1000 in ids else ids[0], unified[0], maps))
        if pids != sorted(int(p.name) for p in Path(proc).iterdir() if p.name.isdecimal()):
            raise Unsupported('process inventory changed')
    except (OSError, UnicodeError, ValueError) as error:
        raise Unsupported('process inventory unavailable') from error
    return result


def set_frozen(cgroup, frozen, timeout=5):
    """Set cgroup v2 freeze and wait for the kernel's matching acknowledgement."""
    directory = Path(cgroup)
    try:
        (directory / 'cgroup.freeze').write_text('1' if frozen else '0')
        deadline = time.monotonic() + timeout
        expected = '1' if frozen else '0'
        while True:
            events = dict(line.split() for line in (directory / 'cgroup.events').read_text().splitlines())
            if events.get('frozen') == expected:
                return
            if time.monotonic() >= deadline:
                raise Unsupported('cgroup freezer did not acknowledge')
            time.sleep(0.02)
    except (OSError, ValueError) as error:
        raise Unsupported('cgroup freezer unavailable') from error


# Linux FITHAW; EINVAL means the filesystem is already thawed (for example,
# after a cold boot).
FITHAW = 0xC0045878


def thaw(root='/', cgroup='/sys/fs/cgroup/caboose-workloads.slice'):
    fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
    try:
        try:
            fcntl.ioctl(fd, FITHAW, 0)
        except OSError as error:
            if error.errno != errno.EINVAL:
                raise
    finally:
        os.close(fd)
    if not Path(cgroup).exists():
        if not Path('/sys/fs/cgroup/cgroup.controllers').exists():
            raise Unsupported('cgroup v2 unavailable')
        return  # A slice absent on the new boot has no frozen processes.
    set_frozen(cgroup, False)


if __name__ == '__main__':
    import sys
    if sys.argv[1:] != ['thaw']:
        raise SystemExit('usage: parked_quiesce.py thaw')
    thaw()
