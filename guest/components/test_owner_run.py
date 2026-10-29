import os
from pathlib import Path
import subprocess
import tempfile
import unittest

WRAPPER = Path(__file__).with_name('caboose-owner-run')

class OwnerRunTest(unittest.TestCase):
    def test_preserves_arguments_and_enters_slice_before_user_drop(self):
        with tempfile.TemporaryDirectory() as directory:
            stub = Path(directory) / 'systemd-run'
            stub.write_text('#!/bin/sh\nprintf "%s\\n" "$@"\n')
            stub.chmod(0o755)
            env = dict(os.environ, PATH=directory)
            result = subprocess.run(['/bin/sh', str(WRAPPER), '/bin/echo', 'a b', '--x'], env=env, text=True, capture_output=True, check=True)
            self.assertEqual(result.stdout.splitlines(), ['--quiet', '--scope', '--slice=caboose-workloads.slice', '--', '/usr/sbin/runuser', '-u', 'caboose', '--', '/bin/echo', 'a b', '--x'])

    def test_empty_command_is_rejected(self):
        result = subprocess.run(['/bin/sh', str(WRAPPER)], capture_output=True)
        self.assertEqual(result.returncode, 2)

if __name__ == '__main__':
    unittest.main()
