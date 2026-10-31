import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('phone_session', Path(__file__).with_name('phone_session.py'))
session = importlib.util.module_from_spec(spec)
spec.loader.exec_module(session)

class Child:
    def __init__(self, code=0): self.returncode = code
    def poll(self): return self.returncode
    def wait(self, timeout=None): return self.returncode

class SessionTests(unittest.TestCase):
    def run_case(self, guest_code, broker_code=0, authenticated=True):
        with tempfile.TemporaryDirectory() as d:
            directory = Path(d)
            directory.chmod(0o700)
            transport = directory / 'transport'; transport.mkdir(mode=0o700)
            if authenticated: (transport / 'guest.sock').touch()
            for name in ('token', 'key.pem', 'cert.pem'): (directory / name).write_text('synthetic')
            config = dict(CABOOSE_GPU_HOST='100.64.0.1', CABOOSE_GPU_PORT='49152',
                          CABOOSE_GPU_SESSION='01'*16, CABOOSE_GPU_GENERATION='1')
            (directory / 'phone-environment.json').write_text(json.dumps(config))
            with patch.object(session.subprocess, 'Popen', side_effect=[Child(broker_code), Child(guest_code)]) as popen, \
                 patch.object(session, 'cleanup_container') as cleanup, \
                 patch.object(session.signal, 'signal'), patch.object(session.signal, 'alarm'):
                status = session.run(directory, Path('/private/guest.py'))
                result = json.loads((directory / 'session-result.json').read_text())
                for name in ('token', 'key.pem', 'cert.pem', 'phone-environment.json'):
                    self.assertFalse((directory / name).exists())
                if authenticated:
                    args = popen.call_args_list[1].args[0]
                    self.assertEqual(args[args.index('--directory')+1], str(transport))
                    cleanup.assert_called_once_with(transport)
                else:
                    self.assertEqual(popen.call_count, 1)
                    cleanup.assert_not_called()
                return status, result

    def test_success_still_requires_phone_identity(self):
        code, result = self.run_case(0)
        self.assertEqual(code, 0)
        self.assertEqual(result['phone_execution'], 'UNVERIFIED')

    def test_guest_failure_cleans_credentials(self):
        code, result = self.run_case(1)
        self.assertEqual(code, 1)
        self.assertEqual(result['status'], 'FAIL')

    def test_no_guest_before_authentication(self):
        code, result = self.run_case(0, broker_code=1, authenticated=False)
        self.assertEqual(code, 1)
        self.assertNotIn('phone_authenticated', result)

    def test_duplicate_session_cannot_cleanup_active_trial(self):
        with tempfile.TemporaryDirectory() as d:
            directory = Path(d); directory.chmod(0o700)
            token = directory / 'token'; token.write_bytes(b'synthetic')
            with session.lock_directory(directory):
                with self.assertRaises(BlockingIOError):
                    session.run(directory, Path('/private/guest.py'))
                self.assertEqual(token.read_bytes(), b'synthetic')
                with self.assertRaises(BlockingIOError):
                    with session.lock_directory(directory):
                        session.cleanup_secrets(directory)
                self.assertTrue(token.exists())

    def test_invalid_config_cleans_owned_credentials(self):
        with tempfile.TemporaryDirectory() as d:
            directory = Path(d); directory.chmod(0o700)
            (directory / 'transport').mkdir(mode=0o700)
            (directory / 'token').write_bytes(b'synthetic')
            (directory / 'phone-environment.json').write_text('{')
            with patch.object(session.signal, 'signal'), patch.object(session.signal, 'alarm'), \
                 patch.object(session.subprocess, 'Popen') as popen:
                self.assertEqual(session.run(directory, Path('/private/guest.py')), 1)
                popen.assert_not_called()
                self.assertFalse((directory / 'token').exists())

    def test_mismatched_container_identity_not_removed(self):
        class Result:
            def __init__(self, stdout): self.stdout=stdout
        with patch.object(session.subprocess, 'run', side_effect=[Result('abc\n'), Result(json.dumps([{'Name':'/wrong', 'Config':{'Labels':{}}}]))]) as run:
            with self.assertRaises(RuntimeError): session.cleanup_container(Path('/private/trial'))
            self.assertEqual(run.call_count, 2)

if __name__ == '__main__': unittest.main()
