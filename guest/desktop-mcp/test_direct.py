import io
import json
import os
import sys
import tempfile
import unittest
import zipfile
from unittest.mock import patch

sys.path.insert(0, os.path.dirname(__file__))
import direct


class Files(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.mkdtemp()
        self.env = patch.dict(os.environ, {'HOME': self.home})
        self.env.start()

    def tearDown(self):
        self.env.stop()

    def test_paths_resolve_inside_the_home_only(self):
        self.assertEqual(direct.inside('~/a/b.txt'), os.path.join(os.path.realpath(self.home), 'a/b.txt'))
        self.assertEqual(direct.inside('a.txt'), os.path.join(os.path.realpath(self.home), 'a.txt'))
        for outside in ('/etc/passwd', '~/../x', '../x'):
            with self.assertRaisesRegex(direct.Failure, 'outside'):
                direct.inside(outside)
        os.symlink('/etc', os.path.join(self.home, 'escape'))
        with self.assertRaisesRegex(direct.Failure, 'outside'):
            direct.inside('~/escape/passwd')

    def test_write_read_list_copy_move(self):
        direct.call({}, 'files.write', {'path': '~/Docs/a.txt', 'text': 'one\n'})
        direct.call({}, 'files.write', {'path': '~/Docs/a.txt', 'text': 'two\n', 'append': True})
        self.assertEqual(direct.call({}, 'files.read', {'path': '~/Docs/a.txt'}), 'one\ntwo\n')
        direct.call({}, 'files.mkdir', {'path': '~/Notes'})
        direct.call({}, 'files.copy', {'from': '~/Docs/a.txt', 'to': '~/Notes'})
        direct.call({}, 'files.move', {'from': '~/Docs/a.txt', 'to': '~/Notes/b.txt'})
        listing = direct.call({}, 'files.list', {'path': '~/Notes'})
        self.assertIn('a.txt (8 bytes)', listing)
        self.assertIn('b.txt (8 bytes)', listing)
        self.assertFalse(os.path.exists(os.path.join(self.home, 'Docs/a.txt')))

    def test_extract_refuses_entries_that_leave_the_target(self):
        archive = os.path.join(self.home, 'bad.zip')
        with zipfile.ZipFile(archive, 'w') as z:
            z.writestr('../../outside.txt', 'x')
        with self.assertRaisesRegex(direct.Failure, 'outside'):
            direct.call({}, 'files.extract', {'archive': '~/bad.zip', 'to': '~/out'})
        good = os.path.join(self.home, 'good.zip')
        with zipfile.ZipFile(good, 'w') as z:
            z.writestr('notes.txt', 'draft')
        self.assertIn('1 entries', direct.call({}, 'files.extract', {'archive': '~/good.zip', 'to': '~/Documents/data'}))
        with open(os.path.join(self.home, 'Documents/data/notes.txt')) as f:
            self.assertEqual(f.read(), 'draft')


try:
    import gi  # noqa: F401  (PyGObject, as on the computer)
    HAVE_GI = True
except ImportError:
    HAVE_GI = False


class Values(unittest.TestCase):
    @unittest.skipUnless(HAVE_GI, 'needs PyGObject')
    def test_json_values_become_typed_variants_or_a_plain_error(self):
        self.assertEqual(direct.to_variant('b', True).unpack(), True)
        self.assertEqual(direct.to_variant('b', 'false').unpack(), False)
        self.assertEqual(direct.to_variant('i', '42').unpack(), 42)
        self.assertEqual(direct.to_variant('as', ['a', 'b']).unpack(), ['a', 'b'])
        with self.assertRaisesRegex(direct.Failure, 'boolean'):
            direct.to_variant('b', 'maybe')

    def test_an_applications_words_name_its_settings(self):
        self.assertEqual(direct.app_words({'app_id': 'org.gnome.FileRoller'}), {'org.gnome.fileroller', 'fileroller'})
        self.assertEqual(direct.app_words({'app_id': 'mousepad'}), {'mousepad'})


class Serve(unittest.TestCase):
    def test_requests_answer_one_json_line_each(self):
        lines = io.StringIO(json.dumps({'op': 'files'}) + '\n' + json.dumps({'op': 'call', 'name': 'files.read', 'args': {'path': '/etc/hosts'}}) + '\n')
        out = io.StringIO()
        with patch.object(direct.sys, 'stdin', lines), patch.object(direct.sys, 'stdout', out):
            direct.serve()
        first, second = [json.loads(l) for l in out.getvalue().splitlines()]
        self.assertIn('files.extract', [t['name'] for t in first['tools']])
        self.assertIn('outside', second['error'])


if __name__ == '__main__':
    unittest.main()
