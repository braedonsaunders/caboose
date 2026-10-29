import importlib.util
import tempfile
import unittest
import json
import hashlib
import fcntl
import os
from pathlib import Path
from types import SimpleNamespace

spec = importlib.util.spec_from_file_location('recovery', Path(__file__).parents[1] / 'offline-recovery.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class RecoveryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bundle = self.root / 'bundle'
        (self.bundle / 'data' / 'state').mkdir(parents=True)
        (self.bundle / 'data' / 'state' / 'identity').write_bytes(b'identity fixture')
        self.data = {'version': 1, 'files': [{'path': 'state/identity', 'bytes': 16, 'sha256': hashlib.sha256(b'identity fixture').hexdigest(), 'mode': 0o600}]}
        self.save()

    def save(self):
        (self.bundle / 'manifest.json').write_text(json.dumps(self.data))

    def test_verify_corruption_and_bound(self):
        module.manifest(self.bundle, 100)
        with self.assertRaises(ValueError):
            module.manifest(self.bundle, 1)
        (self.bundle / 'data/state/identity').write_bytes(b'corrupted')
        with self.assertRaises(ValueError):
            module.manifest(self.bundle, 100)

    def test_traversal_duplicates_symlinks(self):
        for path in ['../secret', '/secret', 'state/../secret', 'state//identity']:
            self.data['files'][0]['path'] = path
            self.save()
            with self.assertRaises(ValueError):
                module.manifest(self.bundle, 100)
        self.data['files'][0]['path'] = 'state/identity'
        self.data['files'].append(self.data['files'][0].copy())
        self.save()
        with self.assertRaises(ValueError):
            module.manifest(self.bundle, 100)
        self.data['files'].pop()
        self.save()
        path = self.bundle / 'data/state/identity'
        path.unlink()
        path.symlink_to(self.bundle / 'manifest.json')
        with self.assertRaises(ValueError):
            module.manifest(self.bundle, 100)

    def test_capture_refuses_live_lock(self):
        roots = []
        for label in ['images', 'state', 'config']:
            path = self.root / label
            path.mkdir()
            roots.append(label + '=' + str(path))
        with (self.root / 'images/.host.lock').open('w') as lock:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            with self.assertRaises(BlockingIOError):
                module.capture(SimpleNamespace(root=roots, bundle=str(self.root / 'new'), confirm_stopped=True, max_bytes=1000))
        self.assertFalse((self.root / 'new').exists())

    @unittest.skipUnless(os.uname().sysname == 'Linux', 'GNU sparse cp round trip runs on hosted Linux')
    def test_real_capture_restore(self):
        roots = []
        for label in ['images', 'state', 'config']:
            path = self.root / label
            path.mkdir()
            (path / 'fixture').write_bytes(label.encode())
            roots.append(label + '=' + str(path))
        bundle = self.root / 'new'
        module.capture(SimpleNamespace(root=roots, bundle=str(bundle), confirm_stopped=True, max_bytes=1000))
        target = self.root / 'restored'
        args = SimpleNamespace(bundle=str(bundle), confirm_restore=True, destination=str(target), max_bytes=1000)
        module.restore(args)
        self.assertEqual((target / 'state/fixture').read_bytes(), b'state')
        self.assertEqual((target / 'config/fixture').stat().st_mode & 0o777, 0o600)
        with self.assertRaises(ValueError):
            module.restore(args)


if __name__ == '__main__':
    unittest.main()
