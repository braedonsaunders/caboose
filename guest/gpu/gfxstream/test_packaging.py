import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import fix_instance_gate
import make_manifest


class PackagingTests(unittest.TestCase):
    def test_gate_is_inserted_before_allocation_and_refuses_modified_source(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = root / fix_instance_gate.PATH
            target.parent.mkdir(parents=True)
            data = fix_instance_gate.ANCHOR.encode()
            target.write_bytes(data)
            with patch.object(fix_instance_gate, 'EXPECTED', hashlib.sha256(data).hexdigest()):
                fix_instance_gate.apply(root)
                text = target.read_text()
                self.assertLess(text.index('VK_ERROR_INCOMPATIBLE_DRIVER'),
                                text.index('struct gfxstream_vk_instance* instance'))
                with self.assertRaises(ValueError):
                    fix_instance_gate.apply(root)

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
