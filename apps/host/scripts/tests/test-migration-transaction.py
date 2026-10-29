#!/usr/bin/env python3
import importlib.util
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
