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


def plan_freezer_branches(nodes, trusted):
    """Plan disjoint whole cgroup branches, leaving only trusted PIDs unfrozen.

    `nodes` maps absolute cgroup-v2 paths to their direct cgroup.procs PIDs.
    The caller must fence admission and revalidate the tree after freezing; a
    plan made from an isolated proc scan does not establish snapshot authority.
    """
    trusted = set(trusted)
    if '/' not in nodes or not trusted:
        raise Unsupported('incomplete cgroup tree or trusted set')
    parents = {}
    seen = set()
    for path, pids in nodes.items():
        if not isinstance(path, str) or not path.startswith('/') or (path != '/' and any(part in ('', '.', '..') for part in path[1:].split('/'))):
            raise Unsupported('invalid cgroup path')
        for pid in pids:
            if not isinstance(pid, int) or pid <= 0 or pid in seen:
                raise Unsupported('invalid or duplicate process')
            seen.add(pid)
        if path != '/':
            parent = path.rsplit('/', 1)[0] or '/'
            if parent not in nodes:
                raise Unsupported('incomplete cgroup tree')
            parents[path] = parent
    if not trusted.issubset(seen):
        raise Unsupported('trusted process missing')
    protected = {'/'}
    for path, pids in nodes.items():
        if trusted.intersection(pids):
            while path != '/':
                protected.add(path)
                path = parents[path]
    for path in protected:
        if set(nodes[path]) - trusted:
            raise Unsupported('unaccounted process shares recovery ancestry')
    return sorted(path for path, parent in parents.items() if parent in protected and path not in protected)


def cgroup_tree(root='/sys/fs/cgroup', max_groups=8192, max_pids=131072):
    """Read a bounded cgroup-v2 tree; any race or inaccessible entry fails closed."""
    nodes = {}
    pending = [('/', Path(root))]
    total = 0
    try:
        while pending:
            path, directory = pending.pop()
            if len(nodes) >= max_groups:
                raise Unsupported('cgroup tree too large')
            raw = (directory / 'cgroup.procs').read_text()
            pids = [int(line) for line in raw.splitlines()]
            total += len(pids)
            if total > max_pids:
                raise Unsupported('too many processes')
            nodes[path] = pids
            with os.scandir(directory) as entries:
                for entry in entries:
                    if entry.is_symlink():
                        raise Unsupported('symlink in cgroup tree')
                    if entry.is_dir(follow_symlinks=False):
                        pending.append(((path.rstrip('/') + '/' + entry.name), Path(entry.path)))
    except (OSError, ValueError) as error:
        raise Unsupported('cgroup tree unavailable') from error
    return nodes


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


def recovery_ancestry(proc='/proc', pid=None):
    """Return this helper's process ancestry, refusing incomplete or cyclic data."""
    current = os.getpid() if pid is None else pid
    seen = set()
    try:
        while current:
            if current in seen or len(seen) >= 128:
                raise Unsupported('invalid recovery ancestry')
            seen.add(current)
            status = (Path(proc) / str(current) / 'status').read_text()
            parent = re.search(r'^PPid:\s+(\d+)\s*$', status, re.M)
            if not parent:
                raise Unsupported('recovery ancestry unavailable')
            current = int(parent.group(1))
    except (OSError, UnicodeError, ValueError) as error:
        raise Unsupported('recovery ancestry unavailable') from error
    if 1 not in seen:
        raise Unsupported('recovery ancestry does not reach init')
    return sorted(seen)


def prepare(root='/sys/fs/cgroup', proc='/proc'):
    check_mounts((Path(proc) / 'self' / 'mountinfo').read_text())
    nodes = cgroup_tree(root)
    return branch_states(nodes, recovery_ancestry(proc), root)


def freeze(recorded, root='/sys/fs/cgroup', proc='/proc'):
    """Freeze only after the host has durably recorded `recorded`."""
    check_mounts((Path(proc) / 'self' / 'mountinfo').read_text())
    nodes = cgroup_tree(root)
    trusted = recovery_ancestry(proc)
    freeze_branches(nodes, trusted, recorded, root)
    try:
        freeze_filesystem()
    except BaseException:
        # The ioctl may have succeeded before reporting an error. The host must
        # retain its intent if this recovery fails or the helper is interrupted.
        thaw(branches=recorded)
        raise


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


def branch_states(nodes, trusted, root='/sys/fs/cgroup'):
    branches = plan_freezer_branches(nodes, trusted)
    if len(branches) > 256:
        raise Unsupported('too many freezer branches')
    states = []
    for branch in branches:
        if len(branch) > 200 or not re.fullmatch(r'/[A-Za-z0-9_:@.\-]+(?:/[A-Za-z0-9_:@.\-]+)*', branch):
            raise Unsupported('unsupported freezer branch name')
        try:
            events = dict(line.split() for line in (Path(root) / branch.lstrip('/') / 'cgroup.events').read_text().splitlines())
        except (OSError, ValueError) as error:
            raise Unsupported('cgroup freezer state unavailable') from error
        if events.get('frozen') not in ('0', '1'):
            raise Unsupported('cgroup freezer state unavailable')
        states.append({'path': branch, 'frozen': events['frozen'] == '1'})
    return states


def freeze_branches(nodes, trusted, recorded, root='/sys/fs/cgroup'):
    """Freeze planned branches and return those changed by this invocation.

    A caller must durably journal the branch list *before* calling this function
    and retain it until thaw succeeds. This function rechecks the entire tree;
    a changed tree is rejected and every attempted freeze is rolled back.
    """
    if branch_states(nodes, trusted, root) != recorded:
        raise Unsupported('freezer state changed before freeze')
    changed = []
    try:
        for entry in recorded:
            branch = entry['path']
            directory = Path(root) / branch.lstrip('/')
            if not entry['frozen']:
                changed.append(branch)  # A failed write may still have reached the kernel.
                set_frozen(directory, True)
        if cgroup_tree(root) != nodes:
            raise Unsupported('cgroup tree changed during freeze')
        return changed
    except BaseException as error:
        failed = []
        for branch in reversed(changed):
            try: set_frozen(Path(root) / branch.lstrip('/'), False)
            except Exception as failure: failed.append(str(failure))
        if failed:
            raise Unsupported('cgroup rollback failed; recovery is required') from error
        raise


# Linux FITHAW; EINVAL means the filesystem is already thawed (for example,
# after a cold boot).
FIFREEZE = 0xC0045877
FITHAW = 0xC0045878


def freeze_filesystem(root='/'):
    """Flush and freeze the filesystem after all writer branches are stopped.

    The caller must have persisted its recovery intent before invoking this.
    An error can be ambiguous, so recovery must attempt thaw even on failure.
    """
    fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
    try:
        os.sync()
        fcntl.ioctl(fd, FIFREEZE, 0)
    finally:
        os.close(fd)


def thaw(root='/', cgroup='/sys/fs/cgroup/caboose-workloads.slice', branches=None):
    if branches is not None:
        if not isinstance(branches, list) or len(branches) > 256:
            raise Unsupported('invalid recovery branches')
        names = []
        for entry in branches:
            if not isinstance(entry, dict) or set(entry) != {'path', 'frozen'} or type(entry['frozen']) is not bool or not isinstance(entry['path'], str) or len(entry['path']) > 200 or not re.fullmatch(r'/[A-Za-z0-9_:@.\-]+(?:/[A-Za-z0-9_:@.\-]+)*', entry['path']) or any(part in ('.', '..') for part in entry['path'].split('/')):
                raise Unsupported('invalid recovery branch')
            name = entry['path']
            if any(within(name, old) or within(old, name) for old in names):
                raise Unsupported('overlapping recovery branches')
            names.append(name)
    fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
    try:
        try:
            fcntl.ioctl(fd, FITHAW, 0)
        except OSError as error:
            if error.errno != errno.EINVAL:
                raise
    finally:
        os.close(fd)
    if branches is not None:
        if not Path('/sys/fs/cgroup/cgroup.controllers').exists():
            raise Unsupported('cgroup v2 unavailable')
        for entry in reversed(branches):
            directory = Path('/sys/fs/cgroup') / entry['path'].lstrip('/')
            if not entry['frozen'] and directory.exists():
                set_frozen(directory, False)
        return
    if not Path(cgroup).exists():
        if not Path('/sys/fs/cgroup/cgroup.controllers').exists():
            raise Unsupported('cgroup v2 unavailable')
        return  # A slice absent on the new boot has no frozen processes.
    set_frozen(cgroup, False)


if __name__ == '__main__':
    import json
    import sys
    if sys.argv[1:] == ['prepare']:
        print(json.dumps(prepare(), separators=(',', ':')))
    elif len(sys.argv) == 3 and sys.argv[1] == 'freeze':
        freeze(json.loads(sys.argv[2]))
    elif sys.argv[1:] == ['thaw']:
        thaw()
    elif len(sys.argv) == 3 and sys.argv[1] == 'thaw':
        thaw(branches=json.loads(sys.argv[2]))
    else:
        raise SystemExit('usage: parked_quiesce.py prepare | freeze BRANCHES_JSON | thaw [BRANCHES_JSON]')
