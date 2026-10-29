"""Exercise the actual request handler without Linux services or socket listeners."""
import importlib.util
import io
import os
import tempfile
import unittest
from unittest.mock import MagicMock, patch
from pathlib import Path

with tempfile.TemporaryDirectory() as root:
    os.environ['CABOOSE_FILES_ROOT'] = root
    spec = importlib.util.spec_from_file_location('files_keyring', Path(__file__).with_name('caboose-files.py'))
    fs = importlib.util.module_from_spec(spec); spec.loader.exec_module(fs)
    fs.TOKEN = str(Path(root) / 'token')
    Path(fs.TOKEN).write_text('test-token')

    class Endpoint(unittest.TestCase):
        def request(self, body=b'a' * 64, **headers):
            handler = fs.Handler.__new__(fs.Handler)
            handler.headers = {'Authorization': 'Bearer test-token', 'Content-Length': str(len(body)), **headers}
            handler.command = 'POST'; handler.path = '/keyring'
            handler.rfile = io.BytesIO(body); handler.connection = MagicMock(); handler.reply = MagicMock()
            handler.handle_request()
            return handler

        def test_body_only_private_delivery(self):
            with patch.object(fs.subprocess, 'run', return_value=MagicMock(returncode=0, stdout=b'{"state": "ready"}\n')) as run:
                handler = self.request()
            self.assertEqual(run.call_args.kwargs['input'], b'a' * 64)
            self.assertNotIn('a' * 64, repr(run.call_args.args))
            self.assertEqual(handler.reply.call_args.args, (200, {'state': 'ready'}, {'Cache-Control': 'no-store'}))

        def test_reject_bad_auth_body_and_chunked_requests(self):
            with patch.object(fs.subprocess, 'run') as run:
                for body, headers in [(b'', {}), (b'g' * 64, {}), (b'a' * 64, {'Authorization': 'wrong'}),
                                      (b'a' * 64, {'Transfer-Encoding': 'chunked'})]:
                    handler = self.request(body, **headers)
                    self.assertIn(handler.reply.call_args.args[0], (400, 401))
                run.assert_not_called()

        def test_serialized_and_fixed_errors(self):
            with fs.keyring_lock, patch.object(fs.subprocess, 'run') as run:
                self.assertEqual(self.request().reply.call_args.args[0], 409)
                run.assert_not_called()
            with patch.object(fs.subprocess, 'run', side_effect=RuntimeError('secret')):
                handler = self.request()
                self.assertEqual(handler.reply.call_args.args, (503, {'state': 'unavailable'}, {'Cache-Control': 'no-store'}))

    unittest.main()
