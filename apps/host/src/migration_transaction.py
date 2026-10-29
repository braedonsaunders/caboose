"""Durable disk/binding publication; caller must hold the image-root lock.

Recovery always restores the original disk.  The retained original is never
modified, and an unknown binding or disk identity stops recovery for inspection.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import tempfile

ID = re.compile(r'^(?:owner|c-[0-9a-f]{10})$')


def sync_dir(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def atomic_json(path, value):
    fd, name = tempfile.mkstemp(prefix='.migration-write-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as f:
            json.dump(value, f, sort_keys=True, separators=(',', ':'))
            f.write('\n')
            f.flush()
            os.fsync(f.fileno())
        os.replace(name, path)
        sync_dir(path.parent)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def identity(path):
    s = os.lstat(path)
    if not stat.S_ISREG(s.st_mode):
        raise ValueError(f'Not a regular file: {path}')
    return [s.st_dev, s.st_ino]


def digest_bytes(data):
    return hashlib.sha256(data).hexdigest()


class Transaction:
    def __init__(self, root, computer):
        if not ID.fullmatch(computer):
            raise ValueError('Invalid computer ID')
        self.dir = Path(root).resolve(strict=True) / 'overlays'
        if not self.dir.is_dir() or self.dir.is_symlink():
            raise ValueError('Invalid overlays directory')
        self.disk = self.dir / f'{computer}.raw'
        self.binding = self.dir / f'{computer}.system-image.json'
        self.journal = self.dir / f'{computer}.migration.json'
        self.original = self.dir / f'.{computer}.migration-original.raw'
        self.staged = self.dir / f'.{computer}.migration-staged.raw'
        self.temp = self.dir / f'.{computer}.migration-restore.raw'
        self.computer = computer

    def publish(self, binding_bytes, checkpoint=lambda phase: None):
        if self.journal.exists() or self.binding.exists() or self.original.exists() or self.temp.exists():
            raise ValueError('Migration artifacts already exist')
        original_id = identity(self.disk)
        staged_id = identity(self.staged)
        if original_id == staged_id:
            raise ValueError('Staged disk is not independent')
        parsed = json.loads(binding_bytes)
        if not isinstance(parsed, dict) or parsed.get('version') != 1:
            raise ValueError('Invalid binding')
        journal = {'version': 1, 'computer': self.computer, 'operation': 'publish',
                   'original': original_id, 'staged': staged_id,
                   'binding_sha256': digest_bytes(binding_bytes), 'phase': 'link-original'}
        atomic_json(self.journal, journal)
        checkpoint('link-original')
        os.link(self.disk, self.original, follow_symlinks=False)
        sync_dir(self.dir)
        journal['phase'] = 'replace-disk'
        atomic_json(self.journal, journal)
        checkpoint('replace-disk')
        os.replace(self.staged, self.disk)
        sync_dir(self.dir)
        journal['phase'] = 'publish-binding'
        atomic_json(self.journal, journal)
        checkpoint('publish-binding')
        # Exact bytes are needed for recovery's ownership check.
        fd, name = tempfile.mkstemp(prefix='.migration-binding-', dir=self.dir)
        try:
            with os.fdopen(fd, 'wb') as f:
                f.write(binding_bytes)
                f.flush()
                os.fsync(f.fileno())
            os.link(name, self.binding)
            sync_dir(self.dir)
        finally:
            if os.path.exists(name):
                os.unlink(name)
        journal['phase'] = 'finish'
        atomic_json(self.journal, journal)
        checkpoint('finish')
        self.journal.unlink()
        sync_dir(self.dir)

    def recover(self):
        data = json.loads(self.journal.read_text())
        if (data.get('version') != 1 or data.get('computer') != self.computer or
            data.get('operation') != 'publish' or data.get('phase') not in
            ('link-original', 'replace-disk', 'publish-binding', 'finish')):
            raise ValueError('Invalid migration journal')
        original, staged = data.get('original'), data.get('staged')
        if not all(isinstance(v, list) and len(v) == 2 and all(isinstance(x, int) and x >= 0 for x in v) for v in (original, staged)):
            raise ValueError('Invalid disk identities')
        binding_hash = data.get('binding_sha256')
        if not isinstance(binding_hash, str) or not re.fullmatch('[0-9a-f]{64}', binding_hash):
            raise ValueError('Invalid binding hash')
        if self.binding.exists():
            identity(self.binding)
            if digest_bytes(self.binding.read_bytes()) != binding_hash:
                raise ValueError('Binding changed during migration; refusing recovery')
        current = identity(self.disk)
        if current not in (original, staged):
            raise ValueError('Disk changed during migration; refusing recovery')
        if self.original.exists() and identity(self.original) != original:
            raise ValueError('Retained disk changed; refusing recovery')
        if current == staged:
            if not self.original.exists():
                raise ValueError('Original disk is missing')
            if self.temp.exists():
                if identity(self.temp) != original:
                    raise ValueError('Unexpected recovery file')
            else:
                os.link(self.original, self.temp, follow_symlinks=False)
                sync_dir(self.dir)
            os.replace(self.temp, self.disk)
            sync_dir(self.dir)
        if self.binding.exists():
            self.binding.unlink()
            sync_dir(self.dir)
        self.journal.unlink()
        sync_dir(self.dir)
