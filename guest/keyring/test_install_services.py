import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('install_services', Path(__file__).with_name('install-services.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class Activation(unittest.TestCase):
    def test_reinstall_removes_stale_and_newly_blocked_registrations(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source, target = root / 'source', root / 'target'
            source.mkdir()
            canonical = root / 'canonical'
            canonical.write_text('[D-BUS Service]\nName=org.freedesktop.secrets\nExec=/synthetic/forwarder\n')
            def service(file, name, command):
                (source / file).write_text(f'[D-BUS Service]\nName={name}\nExec={command}\n')
            service('portal.service', 'org.example.Portal', '/synthetic/portal')
            service('removed.service', 'org.example.Removed', '/synthetic/removed')
            module.reconcile(source, canonical, target)
            (source / 'removed.service').unlink()
            service('portal.service', 'org.example.Portal', '/synthetic/gnome-keyring-daemon')
            service('disguised.service', 'org.freedesktop.secrets', '/synthetic/writer')
            (target / 'old-kwallet.service').write_text('stale writer')
            module.reconcile(source, canonical, target)
            self.assertEqual([p.name for p in target.iterdir()], [module.CANONICAL])
            self.assertEqual((target / module.CANONICAL).read_bytes(), canonical.read_bytes())

    def test_target_symlink_never_modifies_its_destination(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'source').mkdir()
            (root / 'canonical').write_text('synthetic')
            (root / 'untouched').mkdir()
            (root / 'target').symlink_to(root / 'untouched')
            with self.assertRaises(RuntimeError):
                module.reconcile(root / 'source', root / 'canonical', root / 'target')
            self.assertEqual(list((root / 'untouched').iterdir()), [])


if __name__ == '__main__':
    unittest.main()
