import hashlib
import json
from pathlib import Path
import tempfile
import unittest

import make_manifest


class PackagingTests(unittest.TestCase):
    def test_manifest_hash_and_no_overwrite(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            library = root / 'lib.so'
            library.write_bytes(b'fixture')
            digest = hashlib.sha256(b'fixture').hexdigest()
            output = root / 'icd.json'
            with self.assertRaises(ValueError):
                make_manifest.write_manifest(library, '0' * 64, output, '1.3.358')
            self.assertFalse(output.exists())
            make_manifest.write_manifest(library, digest, output, '1.3.358')
            self.assertEqual(json.loads(output.read_text())['ICD']['library_path'], str(library.resolve()))
            with self.assertRaises(FileExistsError):
                make_manifest.write_manifest(library, digest, output, '1.3.358')


if __name__ == '__main__':
    unittest.main()
