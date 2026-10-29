import importlib.util
import inspect
import mimetypes
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('appliance', Path(__file__).resolve().parents[2] / 'src/parked-files-appliance.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class Files:
    def __init__(self, source=None):
        self.files = {'/usr/lib/python3.13/mimetypes.py': (source or inspect.getsource(mimetypes)).encode(), '/etc/mime.types': b'text/x-caboose cbs\ntext/plain txt text\n'}
    def glob_expand(self, pattern): return ['/usr/lib/python3.13/mimetypes.py']
    def filesize(self, path): return len(self.files[path])
    def read_file(self, path): return self.files[path]
    def is_file(self, path): return path in self.files

class MimeTests(unittest.TestCase):
    def test_guest_default_and_system_override_parity(self):
        tables = module.literal_mime(Files())
        expected = mimetypes.MimeTypes()
        expected.add_type('text/x-caboose', '.cbs')
        for name in ('note.txt', 'photo.png', 'data.json', 'archive.tar.gz', 'ARCHIVE.TAR.GZ', 'doc.cbs', 'unknown.zzzz', 'extensionless'):
            self.assertEqual(module.guess_type(tables, name), expected.guess_type(name)[0] or 'application/octet-stream', name)
    def test_guest_code_is_not_executed(self):
        source = inspect.getsource(mimetypes) + '\nraise RuntimeError("guest code must never run")\n'
        self.assertEqual(module.guess_type(module.literal_mime(Files(source)), 'note.txt'), 'text/plain')
    def test_executable_table_is_rejected(self):
        source = 'knownfiles=[]\ndef _default_mime_types():\n types_map = dict()\n suffix_map={}\n encodings_map={}\n'
        with self.assertRaises((ValueError, TypeError)):
            module.literal_mime(Files(source))
    def test_bounded_binary_read(self):
        class G:
            def pread(self, path, count, offset): return b'\x00\xff'
        self.assertEqual(module.dispatch(G(), {'command': 'pread', 'args': ['/note', '0', '2']}, {}), 'AP8=')
        with self.assertRaises(ValueError):
            module.dispatch(G(), {'command': 'pread', 'args': ['/note', '0', '999999999']}, {})

if __name__ == '__main__': unittest.main()
