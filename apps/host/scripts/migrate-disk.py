#!/usr/bin/env python3
"""Offline legacy disk migration. Requires the host to be stopped."""
import argparse
import fcntl
import hashlib
import json
import os
import re
from pathlib import Path
import shutil
import stat
import struct
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'src'))
from migration_transaction import Transaction, atomic_json, identity, present, sync_dir, rollback, recover
from migration_appliance_guard import members, references
from migration_appliance import ApplianceError, matching_kernel, pack_system_image, prepare_system_disk, rebuild_initramfs, trusted_executable

LOCK_FD = None
DISK_LOCKS = {}
# Official v54 and the checksum-pinned AppKit incremental.1 releases.
SUPPORTED_VMM = {
    'x86_64': {'4f4f98a3d661a40f3e5272627cc895a1b2e525f2f6bedf5f895f9cd21ba5c65b', 'e9bd0ed2ae5b5428d275875c340b26ee28bf859ce5d3529d676569a8ed35505e'},
    'aarch64': {'e8a6d9786ea678e739f1a386682846e93742dcb9c7b6e3e0c62e3bda6cff0ef3', '8eb570c73795313e601ff8ef9a6a9132838bf9726d589c4838996d47625caf47'},
}


def run(*args, **kwargs):
    subprocess.run(args, check=True, pass_fds=(() if LOCK_FD is None else (LOCK_FD, *DISK_LOCKS.values())), **kwargs)


def clone_or_copy(source, destination):
    try:
        run('/usr/bin/cp', '--archive', '--preserve=all', '--reflink=always', '--sparse=auto', '--', str(source), str(destination))
    except subprocess.CalledProcessError:
        # The destination is a newly created staging file, never a live disk.
        Path(destination).unlink(missing_ok=True)
        run('/usr/bin/cp', '--archive', '--preserve=all', '--reflink=never', '--sparse=always', '--', str(source), str(destination))


def sha(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def locked(root):
    path = root / '.host.lock'
    try:
        fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    except FileExistsError:
        fd = os.open(path, os.O_RDWR | os.O_NOFOLLOW)
    else:
        # The first migration may precede the first lock-aware host. Preserve
        # the image-root owner's ability to start that host afterward.
        owner = root.stat()
        os.fchown(fd, owner.st_uid, owner.st_gid)
        os.fsync(fd)
        sync_dir(root)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return fd
    except BaseException:
        os.close(fd)
        raise


def assert_cold(tx):
    for pattern in (f'{tx.computer}.snapshot*', f'.{tx.computer}.snapshot-*'):
        for path in tx.dir.glob(pattern):
            raise RuntimeError(f'Parked memory or related snapshot state exists: {path}')


def assert_no_live_disk(tx):
    """Conservatively refuse any live VMM, host, or process holding the disk."""
    disk_id = identity(tx.disk)
    proc = Path('/proc')
    if not proc.is_dir():
        raise RuntimeError('Cannot inspect host processes')
    for entry in proc.iterdir():
        if not entry.name.isdecimal() or int(entry.name) == os.getpid():
            continue
        try:
            argv = (entry / 'cmdline').read_bytes().split(b'\0')
            # Older host processes do not necessarily hold the host lock.  An
            # identifiable host on a different image root is harmless; an
            # ambiguous host is refused instead of guessing at its ownership.
            executable = os.path.basename(os.fsdecode(argv[0])) if argv and argv[0] else ''
            host_entry = any(arg == b'src/index.ts' or arg.endswith(b'/apps/host/dist/index.js') or arg.endswith(b'/caboose-host/src/index.ts') for arg in argv)
            if executable in ('node', 'tsx') and host_entry:
                environ = (entry / 'environ').read_bytes().split(b'\0')
                roots = [value.split(b'=', 1)[1] for value in environ if value.startswith(b'CABOOSE_IMAGE_ROOT=')]
                if len(roots) != 1 or not roots[0].startswith(b'/'):
                    raise RuntimeError(f'Cannot establish image root of host pid {entry.name}')
                other = entry / 'root' / os.fsdecode(roots[0]).lstrip('/')
                other_stat = other.stat()
                ours = tx.dir.parent.stat()
                if (other_stat.st_dev, other_stat.st_ino) == (ours.st_dev, ours.st_ino):
                    raise RuntimeError(f'Host pid {entry.name} uses this image root')
            for fd in (entry / 'fd').iterdir():
                try:
                    st = fd.stat()
                    if [st.st_dev, st.st_ino] == disk_id:
                        raise RuntimeError(f'Disk is open by pid {entry.name}')
                except FileNotFoundError:
                    pass
        except FileNotFoundError:
            continue
        except PermissionError as error:
            raise RuntimeError(f'Cannot inspect pid {entry.name}') from error


def verify_backend(path, root):
    expected = SUPPORTED_VMM.get(os.uname().machine)
    if not expected or not path.is_absolute():
        raise RuntimeError('Migration requires the pinned Cloud Hypervisor v54 backend')
    binary = trusted_executable(path, owners=(0, root.stat().st_uid))
    if not os.access(binary, os.X_OK) or sha(binary) not in expected:
        raise RuntimeError('Migration requires the pinned Cloud Hypervisor v54 backend')


def ensure_environment(root):
    if sys.platform != 'linux' or os.geteuid() != 0:
        raise RuntimeError('Migration requires Linux root')
    if not root.is_absolute() or root.is_symlink() or not root.is_dir():
        raise RuntimeError('Image root must be an existing absolute directory')
    if not hasattr(fcntl, 'F_OFD_SETLK'):
        raise RuntimeError('Kernel OFD disk locking is unavailable')


def lock_disk(path):
    """Lock the entire disk against Cloud Hypervisor's OFD byte-range lock."""
    fd = os.open(path, os.O_RDWR | os.O_NOFOLLOW)
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            raise RuntimeError(f'Not a regular disk: {path}')
        key = (st.st_dev, st.st_ino)
        if key in DISK_LOCKS:
            return
        # Linux struct flock on supported 64-bit architectures: short, short,
        # off_t, off_t, pid_t, with trailing ABI padding. len=0 covers EOF.
        request = struct.pack('hhqqi4x', fcntl.F_WRLCK, os.SEEK_SET, 0, 0, 0)
        fcntl.fcntl(fd, fcntl.F_OFD_SETLK, request)
        DISK_LOCKS[key] = fd
        fd = None
    finally:
        if fd is not None:
            os.close(fd)



def prepare_quiescent(tx):
    record = json.loads(tx.journal.read_text())
    if (record.get('version') != 1 or record.get('operation') != 'prepare' or
        record.get('computer') != tx.computer or record.get('phase') not in ('reserved', 'running', 'idle')):
        raise RuntimeError('Invalid preparation journal')
    if record['phase'] == 'running':
        boot = Path('/proc/sys/kernel/random/boot_id').read_text().strip()
        recorded_boot = record.get('boot_id')
        if not isinstance(recorded_boot, str) or not re.fullmatch(r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}', recorded_boot):
            raise RuntimeError('Invalid appliance boot identity')
        if recorded_boot == boot:
            if record.get('pid_namespace') != os.stat('/proc/self/ns/pid').st_ino:
                raise RuntimeError('Cannot verify appliance in another PID namespace')
            group = record.get('process_group')
            if not isinstance(group, int) or group <= 1:
                raise RuntimeError('Invalid appliance process group')
            if members(group):
                raise RuntimeError('The interrupted migration appliance is still running')
            directory = record.get('appliance_dir')
            disks = record.get('appliance_disks')
            store = (tx.dir.parent / 'migration-images').resolve()
            if not isinstance(directory, str) or not Path(directory).is_absolute() or not Path(directory).resolve().is_relative_to(store):
                raise RuntimeError('Invalid appliance work directory')
            if (not isinstance(disks, list) or not disks or
                any(not isinstance(path, str) or not Path(path).is_absolute() or
                    not (Path(path).resolve() == tx.staged or Path(path).resolve().is_relative_to(store))
                    for path in disks)):
                raise RuntimeError('Invalid appliance disk paths')
            if references([directory, *disks], (os.getpid(),)):
                raise RuntimeError('An unverified process still references the appliance')


def image_store(root):
    images = root / 'migration-images'
    images.mkdir(mode=0o711, exist_ok=True)
    st = os.lstat(images)
    if not stat.S_ISDIR(st.st_mode):
        raise RuntimeError('Migration image store must be a directory')
    # Individual images are private to the disk owner; search permission on the
    # parent lets a non-root host reach its own retained image.
    if not st.st_mode & 0o001:
        os.chmod(images, stat.S_IMODE(st.st_mode) | 0o001)
    return images


def archive_previous_rollback(tx, root):
    retired = tx.dir / f'.{tx.computer}.migration-retired.raw'
    if not present(tx.original) and not present(retired):
        return
    if present(tx.original) and identity(tx.original) != identity(tx.disk):
        raise RuntimeError('Retained original differs from current disk; inspect it before migrating')
    images = image_store(root)
    archive = Path(tempfile.mkdtemp(prefix=f'{tx.computer}-rollback-', dir=images))
    sync_dir(images)
    if present(tx.original):
        # Make the historical copy independent before the live original can be written.
        clone_or_copy(tx.original, archive / 'original.raw')
        with (archive / 'original.raw').open('rb') as f:
            os.fsync(f.fileno())
        sync_dir(archive)
        tx.original.unlink()
        sync_dir(tx.dir)
    if present(retired):
        identity(retired)
        os.replace(retired, archive / 'migrated.raw')
        sync_dir(archive)
        sync_dir(tx.dir)


def retain_unpublished_stage(tx, root):
    if not present(tx.staged):
        raise RuntimeError('No interrupted migration journal or staged disk')
    identity(tx.staged)
    images = image_store(root)
    archive = Path(tempfile.mkdtemp(prefix=f'{tx.computer}-interrupted-', dir=images))
    sync_dir(images)
    os.replace(tx.staged, archive / 'staged.raw')
    sync_dir(archive)
    sync_dir(tx.dir)
    print(f'Retained unpublished staged disk at {archive}')


def migrate(tx, root, mkfs, fsck):
    if present(tx.binding) or present(tx.staged) or present(tx.journal):
        raise RuntimeError('Migration artifacts or system binding already exist')
    archive_previous_rollback(tx, root)
    for program in ('/usr/bin/cp', '/usr/bin/guestfish', '/usr/bin/prlimit', '/usr/bin/awk', '/usr/bin/getfattr', mkfs, fsck):
        trusted_executable(program)
    kernel = root / 'vmlinux'
    identity(kernel)
    owner = os.stat(tx.disk, follow_symlinks=False)
    images = image_store(root)
    image = Path(tempfile.mkdtemp(prefix=f'{tx.computer}-', dir=images))
    sync_dir(images)
    clone_or_copy(tx.disk, tx.staged)
    staged_owner = os.stat(tx.staged, follow_symlinks=False)
    if (staged_owner.st_uid, staged_owner.st_gid, stat.S_IMODE(staged_owner.st_mode)) != (owner.st_uid, owner.st_gid, stat.S_IMODE(owner.st_mode)):
        raise RuntimeError('Disk clone ownership or mode was not preserved')
    here = Path(__file__).resolve().parent
    repo = here.parents[2]
    hook = repo / 'guest/image/initramfs/caboose-system'
    atomic_json(tx.journal, {'version': 1, 'operation': 'prepare', 'computer': tx.computer, 'phase': 'reserved'})
    guard = {'journal': tx.journal, 'computer': tx.computer, 'fds': (LOCK_FD, *DISK_LOCKS.values())}
    version = matching_kernel(tx.staged, kernel, image, guard=guard)
    pack_system_image(tx.staged, image / 'system.erofs', image, mkfs=mkfs, fsck=fsck, guard=guard)
    # Hooks can modify or escape their chroot, but they see only this isolated
    # disposable copy. The final staged disk is not attached to that VM.
    hook_clone = image / 'hook-clone.raw'
    clone_or_copy(tx.staged, hook_clone)
    rebuild_initramfs(hook_clone, tx.staged, version, hook, image / 'initrd', image, guard=guard)
    hook_clone.unlink()
    sync_dir(image)
    # A fresh VM makes fixed filesystem edits without executing guest code.
    prepare_system_disk(tx.staged, version, hook, image / 'initrd', image, guard=guard)
    clone_or_copy(tx.staged, image / 'base.raw')
    shutil.copyfile(kernel, image / 'vmlinux')
    files = ('base.raw', 'vmlinux', 'initrd', 'system.erofs')
    hashes = {}
    for name in files:
        path = image / name
        hashes[name] = sha(path)
        file_owner = path.stat()
        if (file_owner.st_uid, file_owner.st_gid) != (owner.st_uid, owner.st_gid):
            os.chown(path, owner.st_uid, owner.st_gid)
        with path.open('rb') as f:
            os.fsync(f.fileno())
    with tx.staged.open('rb') as f:
        os.fsync(f.fileno())
    os.chown(image, owner.st_uid, owner.st_gid)
    sync_dir(image)
    sync_dir(tx.dir)
    binding = (json.dumps({'version': 1, 'directory': str(image), 'hashes': hashes}, sort_keys=True) + '\n').encode()
    prepare_quiescent(tx)
    tx.journal.unlink()
    sync_dir(tx.dir)
    lock_disk(tx.staged)
    tx.publish(binding)
    print(f'Migrated {tx.computer}; original retained at {tx.original}')


def main():
    parser = argparse.ArgumentParser(description='Offline migration of a cold-stopped legacy computer')
    parser.add_argument('--image-root', required=True, type=Path)
    parser.add_argument('--computer', required=True)
    parser.add_argument('--mkfs', default='/usr/bin/mkfs.erofs')
    parser.add_argument('--fsck', default='/usr/bin/fsck.erofs')
    parser.add_argument('--vmm', type=Path, default=Path(os.environ.get('CABOOSE_VMM_PATH', '/usr/local/bin/cloud-hypervisor')))
    parser.add_argument('command', choices=('inspect', 'migrate', 'recover', 'rollback'))
    parser.add_argument('--discard-migrated-writes', action='store_true')
    args = parser.parse_args()
    root = args.image_root
    ensure_environment(root)
    verify_backend(args.vmm, root)
    root = root.resolve(strict=True)
    global LOCK_FD
    fd = locked(root)
    LOCK_FD = fd
    try:
        tx = Transaction(root, args.computer)
        assert_cold(tx)
        lock_disk(tx.disk)
        if present(tx.original):
            lock_disk(tx.original)
        if present(tx.staged):
            lock_disk(tx.staged)
        assert_no_live_disk(tx)
        if args.command == 'inspect':
            print(json.dumps({'disk': str(tx.disk), 'binding': present(tx.binding),
                              'journal': present(tx.journal), 'original': present(tx.original),
                              'staged': present(tx.staged), 'cold_stopped': True}, indent=2))
        elif args.command == 'migrate':
            migrate(tx, root, args.mkfs, args.fsck)
        elif args.command == 'recover':
            if present(tx.journal):
                record = json.loads(tx.journal.read_text())
                if record.get('operation') == 'prepare':
                    prepare_quiescent(tx)
                    tx.journal.unlink()
                    sync_dir(tx.dir)
                else:
                    recover(tx)
                if present(tx.staged):
                    retain_unpublished_stage(tx, root)
            else:
                retain_unpublished_stage(tx, root)
        else:
            rollback(tx, args.discard_migrated_writes)
    finally:
        LOCK_FD = None
        for disk_fd in DISK_LOCKS.values():
            os.close(disk_fd)
        DISK_LOCKS.clear()
        os.close(fd)


if __name__ == '__main__':
    try:
        main()
    except (OSError, RuntimeError, ValueError, subprocess.CalledProcessError, ApplianceError) as error:
        print(f'Migration refused: {error}', file=sys.stderr)
        raise SystemExit(1)
