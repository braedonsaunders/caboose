"""Build a legacy system image in a network-isolated libguestfs appliance.

Only a disposable clone may be passed as input. The source image is added
read-only; the appliance sees no host devices or host filesystem mounts.
"""
import hashlib
import os
from pathlib import Path
import re
import shutil
import signal
import stat
import subprocess
import tempfile


class ApplianceError(RuntimeError):
    pass


def trusted_executable(path):
    path = Path(path).resolve(strict=True)
    info = path.stat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o022:
        raise ApplianceError(f'Tool must be root-owned and not group/world writable: {path}')
    return path


def dependencies(path):
    """Collect the host package's shared libraries for upload into the appliance."""
    result = subprocess.run(['/usr/bin/ldd', str(path)], capture_output=True, text=True, timeout=30, check=False)
    if result.returncode and 'not a dynamic executable' not in result.stderr:
        raise ApplianceError(f'Cannot inspect tool dependencies: {path}')
    libraries = {}
    for line in result.stdout.splitlines():
        if 'not found' in line:
            raise ApplianceError(f'Missing tool dependency: {line.strip()}')
        match = re.search(r'=>\s+(/\S+)', line)
        if match:
            source = trusted_executable(match.group(1))
            name = match.group(1).rsplit('/', 1)[-1]
            if name in libraries and libraries[name] != source:
                raise ApplianceError(f'Conflicting tool library: {name}')
            libraries[name] = source
    return libraries


def _guestfish(args, env, log_path, timeout, size_limit):
    with open(log_path, 'wb') as log:
        command = ['/usr/bin/prlimit', f'--fsize={size_limit}:{size_limit}', '--', *args]
        proc = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT,
                                env=env, start_new_session=True)
        try:
            status = proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired as error:
            raise ApplianceError('Migration appliance timed out') from error
        finally:
            # guestfish normally reaps QEMU. Also terminate the private process
            # group on an abnormal exit, when an appliance may outlive guestfish.
            try:
                os.killpg(proc.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            if proc.poll() is None:
                try:
                    proc.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    try:
                        os.killpg(proc.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    proc.wait()
    if status:
        with open(log_path, 'rb') as log:
            log.seek(0, os.SEEK_END)
            log.seek(max(0, log.tell() - 16384))
            detail = log.read().decode('utf-8', errors='replace')
        raise ApplianceError(f'Migration appliance failed: {detail}')
    if log_path.stat().st_size > 1024 * 1024:
        raise ApplianceError('Migration appliance returned excessive output')
    return log_path.read_text(encoding='utf-8', errors='replace')


def pack_system_image(clone, output, work, *, guestfish='/usr/bin/guestfish',
                      mkfs='/usr/bin/mkfs.erofs', fsck='/usr/bin/fsck.erofs', awk='/usr/bin/awk', timeout=3600):
    """Pack usr and opt from a read-only clone. This function never runs guest code."""
    clone = Path(clone)
    if clone.is_symlink():
        raise ApplianceError('Clone must not be a symlink')
    clone = clone.resolve(strict=True)
    output = Path(output)
    work = Path(work).resolve(strict=True)
    work_stat = work.stat()
    if work_stat.st_uid != os.geteuid() or work_stat.st_mode & 0o077:
        raise ApplianceError('Appliance work directory must be private and owned by the caller')
    if not output.is_absolute() or output.parent.resolve(strict=True) != work or output.exists() or output.is_symlink():
        raise ApplianceError('Output must be a new path in the private work directory')
    if not clone.is_file() or clone.is_symlink():
        raise ApplianceError('Clone must be a regular file')
    size = clone.stat().st_size
    if size <= 0 or size > 1024 ** 4:
        raise ApplianceError('Unsupported clone size')
    scratch_size = size * 2 + 1024 ** 3
    space = os.statvfs(work)
    # Account for scratch, transfer, log, and the read-only disk's COW overlay.
    if space.f_bavail * space.f_frsize < scratch_size * 4 + 1024 ** 3:
        raise ApplianceError('Insufficient free space for bounded appliance output')
    trusted_executable('/usr/bin/prlimit')
    fish = trusted_executable(guestfish)
    mkfs = trusted_executable(mkfs)
    fsck = trusted_executable(fsck)
    awk = trusted_executable(awk)
    libs = dependencies(mkfs)
    for tool in (fsck, awk):
        for name, path in dependencies(tool).items():
            if name in libs and libs[name] != path:
                raise ApplianceError(f'Conflicting tool library: {name}')
            libs[name] = path
    env = {k: v for k, v in os.environ.items()
           if not k.startswith(('LIBGUESTFS_', 'LD_')) and k not in ('TMPDIR', 'TMP', 'TEMP')}
    env['LIBGUESTFS_BACKEND'] = 'direct'
    with tempfile.TemporaryDirectory(prefix='.migration-appliance-', dir=work) as directory:
        directory = Path(directory)
        env['LIBGUESTFS_CACHEDIR'] = str(directory)
        env['TMPDIR'] = str(directory)
        scratch = directory / 'scratch.raw'
        with scratch.open('xb') as f:
            f.truncate(scratch_size)
        commands = [str(fish), 'add-drive', str(clone), 'readonly:true', 'format:raw', ':',
                    'add-drive', str(scratch), 'format:raw', ':',
                    'set-network', 'false', ':', 'set-memsize', '1024', ':', 'run', ':',
                    'mount-options', 'ro', '/dev/sda3', '/', ':',
                    'debug', 'sh', 'for p in usr opt tmp; do test -d /sysroot/$p && test ! -L /sysroot/$p || exit 1; done', ':',
                    'mkfs', 'ext4', '/dev/sdb', ':', 'mount', '/dev/sdb', '/tmp', ':' , 'debug', 'sh', 'mkdir -p /tmp/caboose-libs', ':',
                    'debug-upload', str(mkfs), '/tmp/caboose-mkfs', '493', ':',
                    'debug-upload', str(fsck), '/tmp/caboose-fsck', '493', ':',
                    'debug-upload', str(awk), '/tmp/caboose-awk', '493', ':']
        for name, path in sorted(libs.items()):
            commands += ['debug-upload', str(path), f'/tmp/caboose-libs/{name}', '493', ':']
        # Refuse links crossing the packed trees: an EROFS lower cannot share
        # an inode with files left on the writable root. Check within the VM.
        script = ('set -eu; export LD_LIBRARY_PATH=/tmp/caboose-libs; '
                  'find /sysroot/usr /sysroot/opt -xdev ! -type d -links +1 -printf "%D:%i %n\\n" > /tmp/caboose-links; '
                  'sort /tmp/caboose-links > /tmp/caboose-links-sorted; '
                  "/tmp/caboose-awk '{ count[$1]++; links[$1]=$2 } END { for (i in count) if (count[i] != links[i]) exit 1 }' /tmp/caboose-links-sorted; "
                  'mkdir /sysroot/tmp/stage; '
                  'cp -a --preserve=all /sysroot/usr /sysroot/opt /sysroot/tmp/stage/; '
                  'export LD_LIBRARY_PATH=/tmp/caboose-libs; '
                  '/tmp/caboose-mkfs -E noinline_data /sysroot/tmp/system.erofs /sysroot/tmp/stage '
                  '>/sysroot/tmp/mkfs.log 2>&1 || { tail -c 16384 /sysroot/tmp/mkfs.log; exit 1; }; '
                  '/tmp/caboose-fsck /sysroot/tmp/system.erofs')
        script_file = directory / 'pack.sh'
        script_file.write_text('#!/bin/sh\n' + script + '\n')
        os.chmod(script_file, 0o700)
        commands += ['debug-upload', str(script_file), '/tmp/caboose-pack.sh', '493', ':',
                     'debug', 'sh', 'sh /tmp/caboose-pack.sh', ':',
                     'download', '/tmp/system.erofs', str(output), ':', 'shutdown']
        try:
            _guestfish(commands, env, directory / 'appliance.log', timeout, scratch_size)
            with output.open('rb') as result:
                os.fsync(result.fileno())
        except BaseException:
            output.unlink(missing_ok=True)
            raise


def _private_work(work):
    work = Path(work).resolve(strict=True)
    info = work.stat()
    if info.st_uid != os.geteuid() or info.st_mode & 0o077:
        raise ApplianceError('Appliance work directory must be private and owned by the caller')
    return work


def _environment(directory):
    env = {k: v for k, v in os.environ.items()
           if not k.startswith(('LIBGUESTFS_', 'LD_')) and k not in ('TMPDIR', 'TMP', 'TEMP')}
    env['LIBGUESTFS_BACKEND'] = 'direct'
    env['LIBGUESTFS_CACHEDIR'] = str(directory)
    env['TMPDIR'] = str(directory)
    return env


def _disk_commands(fish, disk, readonly):
    args = [str(fish), 'add-drive', str(disk)]
    if readonly:
        args.append('readonly:true')
    return args + ['format:raw', ':', 'set-network', 'false', ':', 'set-memsize', '1024', ':',
                   'run', ':', 'mount-options', 'ro' if readonly else 'rw', '/dev/sda3', '/', ':']


def _require_space(work, required):
    space = os.statvfs(work)
    if space.f_bavail * space.f_frsize < required:
        raise ApplianceError('Insufficient free space for bounded appliance execution')


def matching_kernel(clone, kernel, work, *, guestfish='/usr/bin/guestfish', timeout=600):
    """Find the installed kernel matching the legacy VMM kernel, without running guest code."""
    clone, kernel = Path(clone).resolve(strict=True), Path(kernel).resolve(strict=True)
    work = _private_work(work)
    fish = trusted_executable(guestfish)
    trusted_executable('/usr/bin/prlimit')
    if not clone.is_file() or not kernel.is_file() or kernel.stat().st_size > 256 * 1024 ** 2:
        raise ApplianceError('Invalid clone or legacy kernel')
    size = clone.stat().st_size
    if size <= 0 or size > 1024 ** 4:
        raise ApplianceError('Unsupported clone size')
    _require_space(work, 2 * size + 2 * 1024 ** 3)
    digest = hashlib.sha256()
    with kernel.open('rb') as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b''):
            digest.update(chunk)
    expected = digest.hexdigest()
    script = ('set -eu; test -d /sysroot/boot; test ! -L /sysroot/boot; '
              'set -- /sysroot/boot/vmlinuz-*; test "$#" -le 32; '
              'for f do test -f "$f" && test ! -L "$f" || continue; '
              'test "$(stat -c %s "$f")" -le 268435456; sha256sum "$f"; done')
    with tempfile.TemporaryDirectory(prefix='.migration-kernel-', dir=work) as directory:
        directory = Path(directory)
        script_file = directory / 'kernel-check.sh'
        script_file.write_text('#!/bin/sh\n' + script + '\n')
        os.chmod(script_file, 0o700)
        args = _disk_commands(fish, clone, True) + [
            'debug-upload', str(script_file), '/tmp/caboose-kernel.sh', '493', ':',
            'debug', 'sh', 'sh /tmp/caboose-kernel.sh', ':', 'shutdown']
        result = _guestfish(args, _environment(directory), directory / 'appliance.log', timeout,
                            clone.stat().st_size + 1024 ** 3)
    matches = []
    for line in result.splitlines():
        match = re.fullmatch(r'([0-9a-f]{64})  /sysroot/boot/vmlinuz-([0-9][A-Za-z0-9._+~-]*)', line)
        if match and match.group(1) == expected:
            matches.append(match.group(2))
    if len(matches) != 1:
        raise ApplianceError('The legacy kernel does not match exactly one installed kernel')
    return matches[0]


def rebuild_initramfs(hook_clone, source_clone, kernel_version, hook, output, work, *,
                      guestfish='/usr/bin/guestfish', timeout=3600):
    """Execute guest initramfs hooks only on an independent disposable clone in a VM.

    The VM is stopped before another read-only appliance downloads the resulting
    initramfs. The source clone, used for the eventual migrated disk, is never
    attached to the VM that executes tenant-controlled hooks.
    """
    hook_clone, source_clone = Path(hook_clone), Path(source_clone)
    if hook_clone.is_symlink() or source_clone.is_symlink():
        raise ApplianceError('Disk clones must not be symlinks')
    hook_clone, source_clone = hook_clone.resolve(strict=True), source_clone.resolve(strict=True)
    work = _private_work(work)
    if hook_clone.parent != work or not hook_clone.is_file() or not source_clone.is_file():
        raise ApplianceError('Hook execution requires a private disposable clone')
    a, b = hook_clone.stat(), source_clone.stat()
    if (a.st_dev, a.st_ino) == (b.st_dev, b.st_ino):
        raise ApplianceError('Hook clone must be independent of the source clone')
    if not re.fullmatch(r'[0-9][A-Za-z0-9._+~-]*', kernel_version) or len(kernel_version) > 128:
        raise ApplianceError('Invalid kernel version')
    hook = Path(hook).resolve(strict=True)
    if not hook.is_file() or hook.stat().st_size > 1024 * 1024:
        raise ApplianceError('Invalid initramfs hook')
    output = Path(output)
    if not output.is_absolute() or output.parent.resolve(strict=True) != work or output.exists() or output.is_symlink():
        raise ApplianceError('Output must be a new path in the private work directory')
    size = a.st_size
    if size <= 0 or size > 1024 ** 4:
        raise ApplianceError('Unsupported clone size')
    size_limit = size + 1024 ** 3
    space = os.statvfs(work)
    if space.f_bavail * space.f_frsize < size_limit * 4:
        raise ApplianceError('Insufficient free space for bounded hook execution')
    fish = trusted_executable(guestfish)
    trusted_executable('/usr/bin/prlimit')
    preflight = ('set -eu; for p in etc etc/initramfs-tools etc/initramfs-tools/scripts '
                 'etc/initramfs-tools/scripts/local-bottom etc/initramfs-tools/modules boot; '
                 'do test ! -L /sysroot/$p || exit 1; done; '
                 'test ! -e /sysroot/etc/caboose-split-system; test ! -L /sysroot/etc/caboose-split-system; '
                 'test ! -e /sysroot/etc/initramfs-tools/scripts/local-bottom/caboose-system; '
                 'test ! -L /sysroot/etc/initramfs-tools/scripts/local-bottom/caboose-system; '
                 f'for p in usr usr/lib usr/lib/modules usr/lib/modules/{kernel_version}; '
                 'do test -d /sysroot/$p && test ! -L /sysroot/$p || exit 1; done')
    with tempfile.TemporaryDirectory(prefix='.migration-hook-', dir=work) as directory:
        directory = Path(directory)
        env = _environment(directory)
        args = _disk_commands(fish, hook_clone, False) + [
            'debug', 'sh', preflight, ':',
            'mkdir-p', '/etc/initramfs-tools/scripts/local-bottom', ':',
            'upload', str(hook), '/etc/initramfs-tools/scripts/local-bottom/caboose-system', ':',
            'chmod', '0755', '/etc/initramfs-tools/scripts/local-bottom/caboose-system', ':',
            'write-append', '/etc/initramfs-tools/modules', '\nerofs\noverlay\n', ':',
            'sh', f'/usr/sbin/update-initramfs -u -k {kernel_version}', ':', 'shutdown']
        _guestfish(args, env, directory / 'hook.log', timeout, size_limit)
        # The untrusted guest and every hook process are now gone. A fresh,
        # read-only appliance validates and streams the bounded result.
        initrd = f'/boot/initrd.img-{kernel_version}'
        validate = (f'test ! -L /sysroot/boot && test -f /sysroot{initrd} && test ! -L /sysroot{initrd} && '
                    f'test "$(stat -c %s /sysroot{initrd})" -gt 0 && '
                    f'test "$(stat -c %s /sysroot{initrd})" -le 268435456')
        args = _disk_commands(fish, hook_clone, True) + [
            'debug', 'sh', validate, ':', 'download', initrd, str(output), ':', 'shutdown']
        try:
            _guestfish(args, env, directory / 'download.log', timeout, size_limit)
            with output.open('rb') as result:
                if os.fstat(result.fileno()).st_size > 256 * 1024 ** 2:
                    raise ApplianceError('Initramfs exceeds the size limit')
                os.fsync(result.fileno())
        except BaseException:
            output.unlink(missing_ok=True)
            raise


def prepare_system_disk(staged_clone, kernel_version, hook, initrd, work, *,
                        guestfish='/usr/bin/guestfish', timeout=3600):
    """Apply the split layout through appliance filesystem APIs, without guest execution."""
    staged_clone = Path(staged_clone)
    if staged_clone.is_symlink():
        raise ApplianceError('Staged clone must not be a symlink')
    staged_clone = staged_clone.resolve(strict=True)
    work = _private_work(work)
    if not staged_clone.is_file() or not re.fullmatch(r'[0-9][A-Za-z0-9._+~-]*', kernel_version) or len(kernel_version) > 128:
        raise ApplianceError('Invalid staged clone or kernel version')
    hook, initrd = Path(hook), Path(initrd)
    if (hook.is_symlink() or initrd.is_symlink() or not hook.is_file() or not initrd.is_file()
        or hook.stat().st_size > 1024 * 1024 or initrd.stat().st_size > 256 * 1024 ** 2):
        raise ApplianceError('Invalid hook or initramfs')
    size = staged_clone.stat().st_size
    if size <= 0 or size > 1024 ** 4:
        raise ApplianceError('Unsupported clone size')
    _require_space(work, 2 * size + 2 * 1024 ** 3)
    fish = trusted_executable(guestfish)
    trusted_executable('/usr/bin/prlimit')
    initrd_path = f'/boot/initrd.img-{kernel_version}'
    # Each path to be changed must be an ordinary directory or file, not a
    # guest-controlled symlink. Do not overwrite an existing split hook.
    check = ('set -eu; for p in usr opt etc etc/initramfs-tools etc/initramfs-tools/scripts '
             'etc/initramfs-tools/scripts/local-bottom etc/initramfs-tools/modules boot; '
             'do test ! -L /sysroot/$p || exit 1; done; '
             'test -d /sysroot/usr; test -d /sysroot/opt; '
             'test ! -e /sysroot/etc/caboose-split-system; test ! -L /sysroot/etc/caboose-split-system; '
             'test ! -e /sysroot/etc/initramfs-tools/scripts/local-bottom/caboose-system; '
             'test ! -L /sysroot/etc/initramfs-tools/scripts/local-bottom/caboose-system; '
             f'test -f /sysroot{initrd_path}; test ! -L /sysroot{initrd_path}')
    with tempfile.TemporaryDirectory(prefix='.migration-layout-', dir=work) as directory:
        directory = Path(directory)
        args = _disk_commands(fish, staged_clone, False) + [
            'debug', 'sh', check, ':', 'mkdir-p', '/etc/initramfs-tools/scripts/local-bottom', ':',
            'upload', str(hook.resolve()), '/etc/initramfs-tools/scripts/local-bottom/caboose-system', ':',
            'chmod', '0755', '/etc/initramfs-tools/scripts/local-bottom/caboose-system', ':',
            'write-append', '/etc/initramfs-tools/modules', '\nerofs\noverlay\n', ':',
            'upload', str(initrd.resolve()), initrd_path, ':',
            'touch', '/etc/caboose-split-system', ':',
            'rm-r', '/usr', ':', 'rm-r', '/opt', ':', 'mkdir', '/usr', ':', 'mkdir', '/opt', ':',
            'sync', ':', 'shutdown']
        _guestfish(args, _environment(directory), directory / 'appliance.log', timeout, size + 1024 ** 3)
