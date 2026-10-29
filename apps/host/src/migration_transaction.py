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
            owner = os.stat(self.disk)
            os.fchown(fd, owner.st_uid, owner.st_gid)
            os.fchmod(fd, 0o600)
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


def rollback(tx, acknowledge, checkpoint=lambda phase: None):
    """Journal an acknowledged rollback; retain the migrated disk for inspection."""
    if not acknowledge:
        raise ValueError('Rollback requires explicit acknowledgement of migrated writes')
    if tx.journal.exists() or not tx.original.exists() or not tx.binding.exists():
        raise ValueError('No completed migration to roll back, or recovery is required')
    original, current = identity(tx.original), identity(tx.disk)
    if original == current:
        raise ValueError('Computer already uses the retained original')
    retired = tx.dir / f'.{tx.computer}.migration-retired.raw'
    if retired.exists() or tx.temp.exists():
        raise ValueError('Rollback artifacts already exist')
    identity(tx.binding)
    binding = tx.binding.read_bytes()
    journal = {'version': 1, 'computer': tx.computer, 'operation': 'rollback',
               'original': original, 'current': current,
               'binding_sha256': digest_bytes(binding), 'phase': 'retain-current'}
    atomic_json(tx.journal, journal)
    checkpoint('retain-current')
    finish_rollback(tx, journal, checkpoint)


def finish_rollback(tx, journal, checkpoint=lambda phase: None):
    if (journal.get('version') != 1 or journal.get('computer') != tx.computer or
        journal.get('operation') != 'rollback' or journal.get('phase') not in
        ('retain-current', 'restore-original', 'remove-binding')):
        raise ValueError('Invalid rollback journal')
    original, current = journal.get('original'), journal.get('current')
    if not all(isinstance(v, list) and len(v) == 2 and all(isinstance(x, int) and x >= 0 for x in v) for v in (original, current)):
        raise ValueError('Invalid rollback disk identities')
    binding_hash = journal.get('binding_sha256')
    if not isinstance(binding_hash, str) or not re.fullmatch('[0-9a-f]{64}', binding_hash):
        raise ValueError('Invalid rollback binding hash')
    retired = tx.dir / f'.{tx.computer}.migration-retired.raw'
    if identity(tx.original) != original or identity(tx.disk) not in (original, current):
        raise ValueError('Disk identity changed during rollback')
    if tx.binding.exists():
        identity(tx.binding)
        if digest_bytes(tx.binding.read_bytes()) != binding_hash:
            raise ValueError('Binding changed during rollback')
    if retired.exists() and identity(retired) != current:
        raise ValueError('Retired disk identity changed')
    if not retired.exists():
        if identity(tx.disk) != current:
            raise ValueError('Retired disk is missing')
        os.link(tx.disk, retired, follow_symlinks=False)
        sync_dir(tx.dir)
    journal['phase'] = 'restore-original'
    atomic_json(tx.journal, journal)
    checkpoint('restore-original')
    if identity(tx.disk) != original:
        if tx.temp.exists() and identity(tx.temp) != original:
            raise ValueError('Unexpected rollback file')
        if not tx.temp.exists():
            os.link(tx.original, tx.temp, follow_symlinks=False)
            sync_dir(tx.dir)
        os.replace(tx.temp, tx.disk)
        sync_dir(tx.dir)
    journal['phase'] = 'remove-binding'
    atomic_json(tx.journal, journal)
    checkpoint('remove-binding')
    if tx.binding.exists():
        tx.binding.unlink()
        sync_dir(tx.dir)
    tx.journal.unlink()
    sync_dir(tx.dir)


def recover(tx):
    """Recover an interrupted publication or acknowledged rollback."""
    journal = json.loads(tx.journal.read_text())
    if journal.get('operation') == 'publish':
        tx.recover()
    elif journal.get('operation') == 'rollback':
        finish_rollback(tx, journal)
    else:
        raise ValueError('Invalid migration journal')
