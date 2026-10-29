#!/usr/bin/env python3
"""Protected offline directory bundles. No archive extraction or guest filesystem mounts."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import stat

MAX_FILES = 1_000_000


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(4 * 1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def regular(path):
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode):
        raise ValueError('Non-regular file refused: ' + str(path))
    return info


def walk_error(error):
    raise error


def inventory(root, budget):
    directories, files = [], []
    for directory, dirs, names in os.walk(root, followlinks=False, onerror=walk_error):
        directories.append(Path(directory))
        if len(directories) + len(files) + len(dirs) + len(names) > budget:
            raise ValueError('Too many filesystem entries')
        for name in dirs:
            if Path(directory, name).is_symlink():
                raise ValueError('Symlink directory refused')
        for name in names:
            path = Path(directory, name)
            if name == '.host.lock':
                continue
            regular(path)
            files.append(path)
    return directories, files


def sync_directories(directories):
    for path in sorted(set(directories), key=lambda p: len(p.parts), reverse=True):
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_DIRECTORY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)


def safe_path(root, relative):
    if not isinstance(relative, str) or not relative or relative.startswith('/') or any(p in ('', '.', '..') for p in relative.split('/')):
        raise ValueError('Invalid relative path')
    path = root / relative
    for parent in [path, *path.parents]:
        if parent == root.parent:
            break
        if parent.is_symlink():
            raise ValueError('Symlink refused')
    return path


def manifest(bundle, limit):
    regular(bundle / 'manifest.json')
    if (bundle / 'manifest.json').stat().st_size > 256 * 1024 * 1024:
        raise ValueError('Manifest too large')
    data = json.loads((bundle / 'manifest.json').read_text())
    if data.get('version') != 1 or not isinstance(data.get('files'), list) or len(data['files']) > MAX_FILES:
        raise ValueError('Invalid manifest')
    directories = data.get('directories', [])
    if not isinstance(directories, list) or len(directories) > MAX_FILES:
        raise ValueError('Invalid directory list')
    for relative in directories:
        if not safe_path(bundle / 'data', relative).is_dir():
            raise ValueError('Missing directory')
    seen = set()
    total = 0
    for record in data['files']:
        path = safe_path(bundle / 'data', record['path'])
        if record['path'] in seen or type(record['bytes']) is not int or record['bytes'] < 0 or type(record.get('mode')) is not int or not 0 <= record['mode'] <= 0o777:
            raise ValueError('Invalid file record')
        seen.add(record['path'])
        total += record['bytes']
        if total > limit:
            raise ValueError('Bundle exceeds --max-bytes')
        if regular(path).st_size != record['bytes'] or digest(path) != record['sha256']:
            raise ValueError('Bundle verification failed: ' + record['path'])
    return data


def capture(args):
    if not args.confirm_stopped:
        raise ValueError('Stop the host and every VM/container first; --confirm-stopped is required')
    roots = {}
    for item in args.root:
        name, raw = item.split('=', 1)
        if not name.isidentifier() or name in roots:
            raise ValueError('Root labels must be unique identifiers')
        path = Path(raw)
        if path.is_symlink() or not path.is_dir():
            raise ValueError('Roots must be real directories')
        roots[name] = path.resolve()
    if not {'images', 'state', 'config'} <= roots.keys():
        raise ValueError('Supply images, state and config roots (config contains protected environment/secrets)')
    bundle = Path(args.bundle).absolute()
    for root in roots.values():
        if bundle == root or root in bundle.parents:
            raise ValueError('Bundle must be outside source roots')
    # Linux Caboose and its VMM children retain this same advisory lock.
    fd = os.open(roots['images'] / '.host.lock', os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        inventories = {}
        remaining = MAX_FILES
        for label, root in roots.items():
            directories, files = inventory(root, remaining)
            remaining -= len(directories) + len(files)
            inventories[label] = (directories, files)
        # Split image bindings must be covered, including bindings inside template directories.
        for path in inventories['images'][1]:
            if path.name.endswith('.system-image.json'):
                binding = json.loads(path.read_text())
                dependency = Path(binding['directory']).resolve()
                if not any(dependency == root or root in dependency.parents for root in roots.values()):
                    raise ValueError('An image binding is outside supplied roots; add a dependency root')
        total = sum(regular(path).st_size for _, files in inventories.values() for path in files)
        if total > args.max_bytes:
            raise ValueError('Sources exceed --max-bytes')
        bundle.mkdir(mode=0o700)
        records = []
        directories = []
        for label, root in roots.items():
            for directory in inventories[label][0]:
                relative = label + ('/' + Path(directory).relative_to(root).as_posix() if Path(directory) != root else '')
                safe_path(bundle / 'data', relative).mkdir(mode=0o700, parents=True, exist_ok=True)
                directories.append(relative)
                if len(directories) > MAX_FILES:
                    raise ValueError('Too many directories')
            for source in inventories[label][1]:
                if len(records) >= MAX_FILES:
                    raise ValueError('Too many files')
                relative = label + '/' + source.relative_to(root).as_posix()
                target = safe_path(bundle / 'data', relative)
                before = regular(source)
                target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
                # GNU cp preserves sparse VM files; never reflink across the independent backup.
                import subprocess
                subprocess.run(['cp', '--sparse=always', '--reflink=never', '--', str(source), str(target)], check=True)
                target.chmod(0o600)
                with target.open('rb') as copied:
                    os.fsync(copied.fileno())
                after = regular(source)
                checksum = digest(target)
                if (before.st_ino, before.st_size, before.st_mtime_ns) != (after.st_ino, after.st_size, after.st_mtime_ns) or digest(source) != checksum:
                    raise ValueError('Source changed during offline capture')
                records.append({'path': relative, 'bytes': after.st_size, 'sha256': checksum, 'mode': stat.S_IMODE(after.st_mode) & 0o777})
        # Contains relative names/hashes only, never environment or credential values.
        data = {'version': 1, 'files': records, 'directories': directories}
        with (bundle / 'manifest.json').open('x') as stream:
            json.dump(data, stream)
            stream.flush()
            os.fsync(stream.fileno())
        manifest(bundle, args.max_bytes)
        sync_directories([bundle.parent, bundle, bundle / 'data', *[bundle / 'data' / name for name in directories]])
    finally:
        os.close(fd)


def restore(args):
    if not args.confirm_restore:
        raise ValueError('--confirm-restore is required; destination must not exist')
    bundle = Path(args.bundle).resolve()
    data = manifest(bundle, args.max_bytes)
    target = Path(args.destination).absolute()
    if target.exists() or target.is_symlink():
        raise ValueError('Restore destination must not exist')
    target.mkdir(mode=0o700)
    created_directories = {target, target.parent}
    for relative in data.get('directories', []):
        directory = safe_path(target, relative)
        directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        created_directories.add(directory)
    for record in data['files']:
        source = safe_path(bundle / 'data', record['path'])
        destination = safe_path(target, record['path'])
        destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        for directory in destination.parents:
            if directory == target.parent:
                break
            created_directories.add(directory)
        import subprocess
        subprocess.run(['cp', '--sparse=always', '--reflink=never', '--', str(source), str(destination)], check=True)
        if digest(destination) != record['sha256']:
            raise ValueError('Restored file verification failed')
        # Keep restored secrets private; executable bits retain helper usability.
        destination.chmod(0o600 | (record['mode'] & 0o100))
        with destination.open('rb') as copied:
            os.fsync(copied.fileno())
    sync_directories(created_directories)


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['capture', 'verify', 'restore'])
    parser.add_argument('bundle')
    parser.add_argument('--root', action='append', default=[], metavar='LABEL=PATH')
    parser.add_argument('--confirm-stopped', action='store_true')
    parser.add_argument('--confirm-restore', action='store_true')
    parser.add_argument('--destination')
    parser.add_argument('--max-bytes', type=int, required=True, help='Explicit total logical-byte verification bound')
    args = parser.parse_args()
    if args.max_bytes < 1:
        parser.error('--max-bytes must be positive')
    if args.action == 'restore' and not args.destination:
        parser.error('--destination is required')
    if args.action == 'capture':
        capture(args)
    elif args.action == 'verify':
        manifest(Path(args.bundle).resolve(), args.max_bytes)
    else:
        restore(args)
    print('Verified ' + args.action)


if __name__ == '__main__':
    main()
