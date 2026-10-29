import importlib.machinery
import importlib.util
from pathlib import Path
import unittest

loader = importlib.machinery.SourceFileLoader('keyring', str(Path(__file__).with_name('caboose-keyring')))
spec = importlib.util.spec_from_loader(loader.name, loader)
k = importlib.util.module_from_spec(spec)
loader.exec_module(k)

class Policy(unittest.TestCase):
    def test_fresh(self):
        self.assertEqual(k.action('/', '/', [k.ROOT + '/collection/session'], []), 'create')
    def test_existing(self):
        self.assertEqual(k.action('/login', '/login', ['/login'], ['login.keyring']), 'unlock')
    def test_preserve_ambiguous_state(self):
        for default, login, collections, files in [('/', '/', [], ['orphan.keyring']),
                ('/', '/login', ['/login'], []), ('/other', '/login', ['/other', '/login'], []),
                ('/', '/', ['/other'], [])]:
            with self.subTest(default=default, login=login, files=files):
                with self.assertRaises(k.MigrationRequired):
                    k.action(default, login, collections, files)
    def test_nonempty_random_credential_only(self):
        self.assertEqual(k.credential(b'a' * 64 + b'\n'), b'a' * 64)
        for value in (b'', b'\n', b'a' * 63, b'a' * 65, b'g' * 64, b'a' * 63 + b'\x00'):
            with self.assertRaises(ValueError): k.credential(value)

if __name__ == '__main__': unittest.main()
