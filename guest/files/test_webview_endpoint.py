"""The private file service authenticates and bounds app bridge requests."""
import importlib.util
import io
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import MagicMock, patch

with tempfile.TemporaryDirectory() as root:
    os.environ['CABOOSE_FILES_ROOT'] = root
    spec = importlib.util.spec_from_file_location('files_webview', Path(__file__).with_name('caboose-files.py'))
    fs = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(fs)
    fs.TOKEN = str(Path(root) / 'token')
    Path(fs.TOKEN).write_text('guest-token')

    class Endpoint(unittest.TestCase):
        def request(self, body=b'{}', path='/webview/' + 'a' * 32, **headers):
            handler = fs.Handler.__new__(fs.Handler)
            handler.headers = {'Authorization': 'Bearer guest-token', 'Content-Length': str(len(body)), **headers}
            handler.command = 'POST'
            handler.path = path
            handler.rfile = io.BytesIO(body)
            handler.wfile = io.BytesIO()
            handler.connection = MagicMock()
            handler.reply = MagicMock()
            handler.send_response = MagicMock()
            handler.send_header = MagicMock()
            handler.end_headers = MagicMock()
            handler.handle_request()
            return handler

        def test_private_request_reaches_only_the_selected_socket(self):
            connection = MagicMock()
            connection.__enter__.return_value = connection
            connection.recv.side_effect = [b'\x02\x00\x00\x00', b'{}']
            with patch.object(fs, 'bridge_open', return_value=connection) as opened:
                handler = self.request()
            opened.assert_called_once_with('a' * 32)
            self.assertEqual(handler.send_response.call_args.args, (200,))
            self.assertEqual(handler.wfile.getvalue(), b'{}')
            self.assertEqual(connection.sendall.call_args_list[1].args, (b'{}',))

        def test_unauthenticated_chunked_and_large_requests_are_rejected(self):
            with patch.object(fs, 'bridge_open') as opened:
                self.assertEqual(self.request(Authorization='Bearer owner').reply.call_args.args[0], 401)
                self.assertEqual(self.request(**{'Transfer-Encoding': 'chunked'}).reply.call_args.args[0], 400)
                self.assertEqual(self.request(**{'Content-Length': str(fs.BRIDGE_MAX + 1)}).reply.call_args.args[0], 400)
                opened.assert_not_called()

    unittest.main()
