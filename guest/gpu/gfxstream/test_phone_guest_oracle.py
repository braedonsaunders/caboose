import hashlib
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import phone_guest_oracle as runner


class PhoneGuestOracleTests(unittest.TestCase):
    def test_container_name_is_stable_and_trial_scoped(self):
        trial = Path('/private/test/trial')
        name, digest = runner.container_name(trial)
        self.assertEqual(digest, hashlib.sha256(b'/private/test/trial').hexdigest())
        self.assertEqual(name, 'caboose-phone-oracle-' + digest[:24])
        self.assertNotEqual(name, runner.container_name(Path('/private/test/other'))[0])

    def test_hash_and_missing_socket_fail_before_docker(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'artifact'
            path.write_bytes(b'fixture')
            self.assertEqual(runner.sha256(path), hashlib.sha256(b'fixture').hexdigest())
            # run_locked validates socket existence before querying Docker.
            with patch.object(runner.os, 'getuid', return_value=1000):
                with self.assertRaises((ValueError, FileNotFoundError)):
                    runner.run_locked(directory, str(Path(directory) / 'missing.sock'))


if __name__ == '__main__':
    unittest.main()
