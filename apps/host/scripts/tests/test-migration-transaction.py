#!/usr/bin/env python3
import importlib.util
import os
import stat
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

module = Path(__file__).resolve().parents[2] / 'src/migration_transaction.py'
spec = importlib.util.spec_from_file_location('migration_transaction', module)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


class TransactionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / 'overlays').mkdir()
        self.tx = m.Transaction(self.root, 'owner')
        self.tx.disk.write_bytes(b'original')
        self.tx.staged.write_bytes(b'migrated')
        self.binding = b'{"version":1,"directory":"/test","hashes":{}}\n'

    def test_recover_each_interruption(self):
        for phase in ('link-original', 'replace-disk', 'publish-binding', 'finish'):
            with self.subTest(phase=phase), tempfile.TemporaryDirectory() as root:
                (Path(root) / 'overlays').mkdir()
                tx = m.Transaction(root, 'owner')
                tx.disk.write_bytes(b'original')
                tx.staged.write_bytes(b'migrated')
                def crash(actual):
                    if actual == phase:
                        raise RuntimeError('power loss')
                with self.assertRaises(RuntimeError):
                    tx.publish(self.binding, crash)
                tx.recover()
                self.assertEqual(tx.disk.read_bytes(), b'original')
                self.assertFalse(tx.binding.exists())
                self.assertFalse(tx.journal.exists())

    def test_recover_after_each_filesystem_mutation(self):
        for operation in ('original-link', 'disk-replace', 'binding-link'):
            with self.subTest(operation=operation), tempfile.TemporaryDirectory() as root:
                (Path(root) / 'overlays').mkdir()
                tx = m.Transaction(root, 'owner')
                tx.disk.write_bytes(b'original')
                tx.staged.write_bytes(b'migrated')
                real_link, real_replace = m.os.link, m.os.replace
                def link(source, destination, *args, **kwargs):
                    result = real_link(source, destination, *args, **kwargs)
                    if (operation == 'original-link' and destination == tx.original or
                        operation == 'binding-link' and destination == tx.binding):
                        raise RuntimeError('power loss after link')
                    return result
                def replace(source, destination, *args, **kwargs):
                    result = real_replace(source, destination, *args, **kwargs)
                    if operation == 'disk-replace' and destination == tx.disk:
                        raise RuntimeError('power loss after replace')
                    return result
                with patch.object(m.os, 'link', link), patch.object(m.os, 'replace', replace):
                    with self.assertRaisesRegex(RuntimeError, 'power loss'):
                        tx.publish(self.binding)
                tx.recover()
                self.assertEqual(tx.disk.read_bytes(), b'original')
                self.assertFalse(tx.binding.exists())
                self.assertFalse(tx.journal.exists())

    def test_success_retains_original(self):
        self.tx.publish(self.binding)
        self.assertEqual(self.tx.disk.read_bytes(), b'migrated')
        self.assertEqual(self.tx.original.read_bytes(), b'original')
        self.assertEqual(self.tx.binding.read_bytes(), self.binding)
        self.assertFalse(self.tx.journal.exists())

    def test_binding_is_private_and_owned_by_disk_owner(self):
        if os.geteuid() == 0:
            os.chown(self.tx.disk, 1000, 1000)
            os.chown(self.tx.staged, 1000, 1000)
        disk_owner = self.tx.disk.stat()
        self.tx.publish(self.binding)
        binding = self.tx.binding.stat()
        self.assertEqual((binding.st_uid, binding.st_gid), (disk_owner.st_uid, disk_owner.st_gid))
        self.assertEqual(stat.S_IMODE(binding.st_mode), 0o600)

    def test_acknowledged_rollback_retains_post_migration_writes(self):
        self.tx.publish(self.binding)
        self.tx.disk.write_bytes(b'migrated writes')
        with self.assertRaisesRegex(ValueError, 'acknowledgement'):
            m.rollback(self.tx, False)
        m.rollback(self.tx, True)
        self.assertEqual(self.tx.disk.read_bytes(), b'original')
        self.assertEqual((self.tx.dir / '.owner.migration-retired.raw').read_bytes(), b'migrated writes')
        self.assertEqual(self.tx.original.read_bytes(), b'original')
        self.assertFalse(self.tx.binding.exists())
        self.assertFalse(self.tx.journal.exists())

    def test_recover_interrupted_rollback(self):
        for phase in ('retain-current', 'restore-original', 'remove-binding'):
            with self.subTest(phase=phase), tempfile.TemporaryDirectory() as root:
                (Path(root) / 'overlays').mkdir()
                tx = m.Transaction(root, 'owner')
                tx.disk.write_bytes(b'original')
                tx.staged.write_bytes(b'migrated')
                tx.publish(self.binding)
                def crash(actual):
                    if actual == phase:
                        raise RuntimeError('power loss')
                with self.assertRaises(RuntimeError):
                    m.rollback(tx, True, crash)
                m.recover(tx)
                self.assertEqual(tx.disk.read_bytes(), b'original')
                self.assertEqual((tx.dir / '.owner.migration-retired.raw').read_bytes(), b'migrated')
                self.assertFalse(tx.binding.exists())
                self.assertFalse(tx.journal.exists())

    def test_recover_after_rollback_filesystem_mutations(self):
        for operation in ('retire', 'restore-link', 'replace', 'unlink-binding'):
            with self.subTest(operation=operation), tempfile.TemporaryDirectory() as root:
                (Path(root) / 'overlays').mkdir()
                tx = m.Transaction(root, 'owner')
                tx.disk.write_bytes(b'original')
                tx.staged.write_bytes(b'migrated')
                tx.publish(self.binding)
                retired = tx.dir / '.owner.migration-retired.raw'
                real_link, real_replace, real_unlink = m.os.link, m.os.replace, Path.unlink
                def link(source, destination, *args, **kwargs):
                    result = real_link(source, destination, *args, **kwargs)
                    if operation == 'retire' and destination == retired or operation == 'restore-link' and destination == tx.temp:
                        raise RuntimeError('power loss after link')
                    return result
                def replace(source, destination, *args, **kwargs):
                    result = real_replace(source, destination, *args, **kwargs)
                    if operation == 'replace' and destination == tx.disk:
                        raise RuntimeError('power loss after replace')
                    return result
                def unlink(path, *args, **kwargs):
                    result = real_unlink(path, *args, **kwargs)
                    if operation == 'unlink-binding' and path == tx.binding:
                        raise RuntimeError('power loss after unlink')
                    return result
                with patch.object(m.os, 'link', link), patch.object(m.os, 'replace', replace), patch.object(Path, 'unlink', unlink):
                    with self.assertRaisesRegex(RuntimeError, 'power loss'):
                        m.rollback(tx, True)
                m.recover(tx)
                self.assertEqual(tx.disk.read_bytes(), b'original')
                self.assertEqual(retired.read_bytes(), b'migrated')
                self.assertFalse(tx.binding.exists())
                self.assertFalse(tx.journal.exists())

    def test_recovery_rejects_unknown_binding(self):
        def crash(phase):
            if phase == 'finish':
                raise RuntimeError('power loss')
        with self.assertRaises(RuntimeError):
            self.tx.publish(self.binding, crash)
        self.tx.binding.write_bytes(b'foreign')
        with self.assertRaisesRegex(ValueError, 'Binding changed'):
            self.tx.recover()
        self.assertTrue(self.tx.journal.exists())
        self.assertEqual(self.tx.disk.read_bytes(), b'migrated')

    def test_rejects_unsafe_computer_ids(self):
        for value in ('../owner', 'other', 'c-123', ''):
            with self.assertRaises(ValueError):
                m.Transaction(self.root, value)


if __name__ == '__main__':
    unittest.main()
