import importlib.util
import os
import tempfile
import unittest

with tempfile.TemporaryDirectory() as root:
    os.environ['CABOOSE_FILES_ROOT'] = root
    spec = importlib.util.spec_from_file_location('files', os.path.join(os.path.dirname(__file__), 'caboose-files.py'))
    fs = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(fs)

    class Logic(unittest.TestCase):
        def test_paths(self):
            for path in ('../x', '/x', 'x/../y', 'x//y', './x', 'x\0y'):
                with self.assertRaises(ValueError): fs.parts(path)
            os.symlink('/etc', os.path.join(root, 'outside'))
            with self.assertRaises(OSError): fs.directory(['outside'])
        def test_transfer_names(self):
            for name in ('photo 1.png', 'naïve.txt', '.hidden'):
                self.assertEqual(fs.transfer_name(name), name)
            for name in ('', '.', '..', 'a/b', 'a\nb', '.caboose-upload-x', 'x' * 256, None):
                with self.assertRaises(ValueError): fs.transfer_name(name)
            self.assertEqual(fs.transfer_id('0' * 32), '0' * 32)
            for value in ('0' * 31, 'A' * 32, '0' * 32 + '\n', '../' + '0' * 29):
                with self.assertRaises(ValueError): fs.transfer_id(value)
        def test_range(self):
            self.assertEqual(fs.byte_range(None, 5), (0, 4, False))
            self.assertEqual(fs.byte_range('bytes=1-2', 5), (1, 2, True))
            self.assertEqual(fs.byte_range('bytes=-2', 5), (3, 4, True))
            self.assertEqual(fs.byte_range('bytes=1-', 5), (1, 4, True))
            for value in ('bytes=5-', 'bytes=2-1', 'bytes=-0', 'bytes=0-1,3-4', 'no'):
                with self.assertRaises(ValueError): fs.byte_range(value, 5)
        def test_versions(self):
            path = os.path.join(root, 'version')
            with open(path, 'w') as f: f.write('a')
            first = fs.version(os.stat(path))
            with open(path, 'w') as f: f.write('different')
            self.assertNotEqual(first, fs.version(os.stat(path)))
        def test_anchors(self):
            import threading
            changes = fs.Changes.__new__(fs.Changes)
            changes.epoch = 'test'; changes.sequence = 2; changes.guard = threading.Lock(); changes.healthy = True; changes.events = [(2, [{'path': 'a', 'removed': False}])]
            self.assertFalse(changes.changes('test:2')['changed'])
            self.assertEqual(changes.changes('test:1')['events'][0]['path'], 'a')
            self.assertTrue(changes.changes('old:2')['reset'])
    unittest.main()
