#!/usr/bin/python3
"""Reconcile the root-managed agent activation directory without following stale links."""
import configparser
import os
from pathlib import Path
import stat
import sys
import tempfile

CANONICAL = 'org.freedesktop.secrets.service'


def permitted(path):
    config = configparser.ConfigParser(interpolation=None)
    config.read_string(path.read_text())
    service = config['D-BUS Service']
    name = service['Name'].lower()
    fields = ' '.join(service.values()).lower()
    return name != 'org.freedesktop.secrets' and not any(word in fields for word in ('keyring', 'kwallet'))


def reconcile(source, canonical, target):
    desired = {CANONICAL: canonical.read_bytes()}
    for path in source.glob('*.service'):
        if path.name != CANONICAL and permitted(path):
            desired[path.name] = path.read_bytes()
    target.mkdir(mode=0o755, parents=True, exist_ok=True)
    info = target.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
        raise RuntimeError('activation directory must be owned and not a symlink')
    # Reject unexpected nested entries rather than ever recursively deleting content.
    for path in target.iterdir():
        if path.name.endswith('.service') and not path.is_dir():
            continue
        raise RuntimeError('unexpected file in managed activation directory')
    # Remove stale/blocked registrations first. Each allowed registration is then
    # atomically replaced, so readers never observe a partial service file.
    for path in target.iterdir():
        if path.name not in desired:
            path.unlink()
    for name, content in desired.items():
        fd, temporary = tempfile.mkstemp(prefix='.service-', dir=target.parent)
        try:
            with os.fdopen(fd, 'wb') as handle:
                os.fchmod(handle.fileno(), 0o644)
                handle.write(content)
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(temporary, target / name)
        finally:
            Path(temporary).unlink(missing_ok=True)
    fd = os.open(target, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


if __name__ == '__main__':
    reconcile(*(Path(arg) for arg in sys.argv[1:]))
