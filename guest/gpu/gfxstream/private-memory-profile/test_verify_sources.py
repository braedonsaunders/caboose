import hashlib
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import verify_sources

class VerificationTests(unittest.TestCase):
    def test_all_files_checked_and_tamper_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp) / verify_sources.PREFIX
            base.mkdir(parents=True)
            expected = {}
            for name in ('tracker.cpp', 'encoder.cpp', 'table.cpp'):
                (base / name).write_bytes(name.encode())
                expected[name] = hashlib.sha256(name.encode()).hexdigest()
            with patch.object(verify_sources, 'EXPECTED', expected):
                self.assertEqual(verify_sources.verify(temp), expected)
                (base / 'table.cpp').write_bytes(b'drift')
                with self.assertRaisesRegex(ValueError, 'table.cpp'):
                    verify_sources.verify(temp)
                (base / 'encoder.cpp').unlink()
                with self.assertRaises(FileNotFoundError):
                    verify_sources.verify(temp)

if __name__ == '__main__':
    unittest.main()
