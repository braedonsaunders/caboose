#!/usr/bin/env python3
import importlib.util
import json
import shutil
import subprocess
import sys
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

script = Path(__file__).resolve().parents[1] / 'migrate-disk.py'
spec = importlib.util.spec_from_file_location('migrate_disk', script)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


class MigrationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        (root / 'overlays').mkdir()
        self.tx = m.Transaction(root, 'owner')
        self.tx.disk.write_bytes(b'original')
        self.tx.staged.write_bytes(b'split')
        self.tx.publish(b'{"version":1}')

    def test_migration_uses_separate_hook_clone_and_publishes_only_after_preparation(self):
        # Start with a legacy disk rather than the split fixture from setUp.
        self.tx.binding.unlink()
        self.tx.original.unlink()
        root = self.tx.dir.parent
        (root / 'vmlinux').write_bytes(b'kernel')
        events = []
        def copy(source, dest):
            shutil.copyfile(source, dest)
        def match(source, kernel, work, **kwargs):
            events.append('match')
            return '6.12-test'
        def pack(source, output, work, **kwargs):
            events.append('pack')
            output.write_bytes(b'erofs')
        def rebuild(hook_clone, source, version, hook, output, work, **kwargs):
            events.append('hooks')
            self.assertNotEqual(hook_clone.stat().st_ino, source.stat().st_ino)
            hook_clone.write_bytes(b'untrusted hook mutated its copy')
            self.assertEqual(source.read_bytes(), b'split')
            output.write_bytes(b'initrd')
        def prepare(source, version, hook, initrd, work, **kwargs):
            events.append('layout')
            self.assertEqual(source.read_bytes(), b'split')
            source.write_bytes(b'prepared')
        with patch.object(m, 'trusted_executable', side_effect=lambda p, **kwargs: Path(p)), patch.object(m, 'clone_or_copy', copy), \
             patch.object(m, 'matching_kernel', match), patch.object(m, 'pack_system_image', pack), \
             patch.object(m, 'rebuild_initramfs', rebuild), patch.object(m, 'prepare_system_disk', prepare), \
             patch.object(m, 'lock_disk'):
            m.migrate(self.tx, root, '/mkfs', '/fsck')
        self.assertEqual(events, ['match', 'pack', 'hooks', 'layout'])
        self.assertEqual(self.tx.disk.read_bytes(), b'prepared')
        self.assertEqual(self.tx.original.read_bytes(), b'split')
        self.assertTrue(self.tx.binding.exists())
        self.assertFalse(self.tx.journal.exists())

    def test_rollback_artifacts_can_be_archived_for_repeat(self):
        m.rollback(self.tx, True)
        def fake_cp(*args):
            shutil.copyfile(args[-2], args[-1])
        with patch.object(m, 'run', fake_cp):
            m.archive_previous_rollback(self.tx, self.tx.dir.parent)
        self.assertFalse(self.tx.original.exists())
        self.assertFalse((self.tx.dir / '.owner.migration-retired.raw').exists())
        archive = next((self.tx.dir.parent / 'migration-images').iterdir())
        self.tx.disk.write_bytes(b'new legacy writes')
        self.assertEqual((archive / 'original.raw').read_bytes(), b'original')
        self.assertEqual((archive / 'migrated.raw').read_bytes(), b'split')

    def test_copy_falls_back_when_reflinks_are_unavailable(self):
        source = self.tx.disk
        target = self.tx.dir / 'copy.raw'
        calls = []
        def cp(*args):
            calls.append(args)
            if len(calls) == 1:
                target.write_bytes(b'partial')
                raise subprocess.CalledProcessError(1, args)
            self.assertFalse(target.exists())
            shutil.copyfile(args[-2], args[-1])
        with patch.object(m, 'run', cp):
            m.clone_or_copy(source, target)
        self.assertEqual(target.read_bytes(), b'split')
        self.assertIn('--reflink=never', calls[1])

    def test_unpublished_stage_is_retained(self):
        self.tx.staged.write_bytes(b'incomplete stage')
        m.retain_unpublished_stage(self.tx, self.tx.dir.parent)
        self.assertFalse(self.tx.staged.exists())
        archive = next((self.tx.dir.parent / 'migration-images').iterdir())
        self.assertEqual((archive / 'staged.raw').read_bytes(), b'incomplete stage')

    def test_preparation_journal_requires_valid_identity(self):
        self.tx.journal.write_text(json.dumps({'version': 1, 'operation': 'prepare', 'computer': 'owner', 'phase': 'reserved'}))
        m.prepare_quiescent(self.tx)
        self.tx.journal.write_text(json.dumps({'version': 1, 'operation': 'prepare', 'computer': 'other', 'phase': 'idle'}))
        with self.assertRaisesRegex(RuntimeError, 'Invalid preparation journal'):
            m.prepare_quiescent(self.tx)

    def test_backend_digest_must_be_known(self):
        binary = self.tx.dir / 'cloud-hypervisor'
        binary.write_bytes(b'unknown')
        binary.chmod(0o755)
        with patch.object(m, 'trusted_executable', return_value=binary):
            with self.assertRaisesRegex(RuntimeError, 'pinned Cloud Hypervisor'):
                m.verify_backend(binary, self.tx.dir.parent)
            with patch.object(m, 'sha', return_value=m.SUPPORTED_VMM['x86_64']), patch.object(m.os, 'uname') as uname:
                uname.return_value.machine = 'x86_64'
                m.verify_backend(binary, self.tx.dir.parent)

    def test_new_host_lock_owned_by_image_root_owner(self):
        import os
        root = self.tx.dir.parent
        if os.geteuid() == 0:
            os.chown(root, 1000, 1000)
        owner = root.stat()
        fd = m.locked(root)
        os.close(fd)
        lock = (root / '.host.lock').stat()
        self.assertEqual((lock.st_uid, lock.st_gid), (owner.st_uid, owner.st_gid))

    @unittest.skipUnless(sys.platform == 'linux', 'Linux OFD locks')
    def test_disk_ofd_lock_fences_independent_process(self):
        import fcntl
        import os
        import struct
        m.lock_disk(self.tx.disk)
        self.addCleanup(m.DISK_LOCKS.clear)
        self.addCleanup(lambda: [os.close(fd) for fd in m.DISK_LOCKS.values()])
        probe = ("import fcntl,os,struct,sys; "
                 "fd=os.open(sys.argv[1],os.O_RDWR); "
                 "fcntl.fcntl(fd,fcntl.F_OFD_SETLK,struct.pack('hhqqi4x',fcntl.F_WRLCK,os.SEEK_SET,0,0,0))")
        result = subprocess.run([sys.executable, '-c', probe, str(self.tx.disk)], capture_output=True)
        self.assertNotEqual(result.returncode, 0)

    def test_parked_state_blocks(self):
        for name in ('owner.snapshot', 'owner.snapshot.cold.json', 'owner.snapshot.cold-discard', '.owner.snapshot-restore-incomplete', '.owner.snapshot-verify-incomplete'):
            path = self.tx.dir / name
            path.touch()
            with self.assertRaisesRegex(RuntimeError, 'Parked'):
                m.assert_cold(self.tx)
            path.unlink()


if __name__ == '__main__':
    unittest.main()
