#!/usr/bin/python3
"""Disposable Linux measurement/pack check; never accepts an existing disk.

Run with /usr/bin/python3 check-compressed-migration.py --work PRIVATE_PARENT.
Requires root, a readable installed appliance kernel, guestfish/supermin/QEMU,
erofs-utils, attr, awk, prlimit, and at least 21 GiB free on PRIVATE_PARENT.
Each source is 512 MiB with less than 16 MiB logical fixture content. Each
appliance has a 600-second deadline and the production guard/file caps. Failed
fixtures are retained for diagnosis and guard recovery; success removes them.
"""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'src'))
import migration_appliance as m


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--work', required=True, type=Path)
    args = parser.parse_args()
    if sys.platform != 'linux' or os.geteuid() != 0:
        parser.error('Run on a disposable Linux runner as root')
    parent = args.work.resolve(strict=True)
    m._require_space(parent, 21 * 1024 ** 3)
    for program in ('/usr/bin/guestfish', '/usr/bin/prlimit', '/usr/bin/awk',
                    '/usr/bin/getfattr', '/usr/bin/mkfs.erofs', '/usr/bin/fsck.erofs'):
        m.trusted_executable(program)
    root = Path(tempfile.mkdtemp(prefix='caboose-migration-check-', dir=parent))
    lock = os.open(root / 'host.lock', os.O_CREAT | os.O_RDWR, 0o600)
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    journal = root / 'journal.json'
    journal.write_text(json.dumps({'version': 1, 'operation': 'prepare',
                                   'computer': 'fixture', 'phase': 'reserved'}))
    guard = {'journal': journal, 'computer': 'fixture', 'fds': (lock,)}
    success = False
    print(f'Migration fixture: {root}', flush=True)
    try:
        payload = root / 'payload'
        # Very compressible bytes plus a sparse logical file exercise sizes
        # that cannot be inferred from the raw image's allocated host blocks.
        payload.write_bytes(b'caboose-measurement\n' * 65536)
        expected = hashlib.sha256(payload.read_bytes()).hexdigest()
        for filesystem in ('ext4', 'btrfs'):
            disk = root / f'{filesystem}.raw'
            with disk.open('xb') as stream:
                stream.truncate(512 * 1024 ** 2)
            with m._appliance_directory(root, 'create-', guard) as directory:
                commands = ['/usr/bin/guestfish', 'add-drive', str(disk), 'format:raw', ':',
                            'set-network', 'false', ':', 'set-memsize', '1024', ':', 'run', ':',
                            'part-init', '/dev/sda', 'gpt', ':',
                            'part-add', '/dev/sda', 'p', '2048', '4095', ':',
                            'part-add', '/dev/sda', 'p', '4096', '8191', ':',
                            'part-add', '/dev/sda', 'p', '8192', str(512 * 1024 ** 2 // 512 - 34), ':',
                            'mkfs', filesystem, '/dev/sda3', ':',
                            'debug', 'sh', m._mount_root_script(False), ':',
                            'mkdir', '/usr', ':', 'mkdir', '/opt', ':', 'mkdir', '/tmp', ':',
                            'mkdir-p', '/var/lib/caboose', ':',
                            'upload', str(payload), '/usr/probe', ':',
                            'ln', '/usr/probe', '/opt/hardlink', ':',
                            'ln-s', '/does-not-exist', '/usr/symlink', ':',
                            'setxattr', 'user.caboose-test', 'preserved', '9', '/usr/probe', ':',
                            'touch', '/usr/sparse', ':', 'truncate-size', '/usr/sparse', '4194304', ':',
                            'sync', ':', 'shutdown']
                m._guestfish(commands, m._environment(directory), directory / 'create.log',
                             600, m._READONLY_LIMIT, guard)
            before = disk.stat()
            output = root / f'{filesystem}.erofs'
            m.pack_system_image(disk, output, root, timeout=600, guard=guard)
            after = disk.stat()
            assert (before.st_ino, before.st_size, before.st_mtime_ns, before.st_ctime_ns) == (
                after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns)
            assert 0 < output.stat().st_size < 16 * 1024 ** 2
            with m._appliance_directory(root, 'verify-', guard) as directory:
                commands = ['/usr/bin/guestfish', 'add-drive', str(output), 'readonly:true', 'format:raw', ':',
                            'set-network', 'false', ':', 'set-memsize', '1024', ':', 'run', ':',
                            'mount-ro', '/dev/sda', '/', ':',
                            'checksum', 'sha256', '/usr/probe', ':',
                            'checksum', 'sha256', '/opt/hardlink', ':',
                            'getxattr', '/usr/probe', 'user.caboose-test', ':', 'echo', '', ':',
                            'filesize', '/usr/sparse', ':',
                            'readlink', '/usr/symlink', ':', 'shutdown']
                result = m._guestfish(commands, m._environment(directory), directory / 'verify.log',
                                     600, m._READONLY_LIMIT, guard)
            assert result.splitlines() == [expected, expected, 'preserved', '4194304', '/does-not-exist'], result
            print(f'{filesystem}: read-only measured pack, hashes, hardlink content, xattr, sparse size, symlink passed', flush=True)
            output.unlink()
            disk.unlink()
        success = True
    finally:
        os.close(lock)
        if success and m._guard_quiescent(guard):
            shutil.rmtree(root)
        else:
            print(f'Retained failed fixture and guard journal: {root}', file=sys.stderr)


if __name__ == '__main__':
    main()
