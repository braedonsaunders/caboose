import base64, hashlib, json, os, pathlib, socket, struct, subprocess, sys, tempfile, time, unittest

HERE = pathlib.Path(__file__).resolve().parent.parent / 'webmcp'
EXTENSION = HERE / 'extension'


class Extension(unittest.TestCase):
    def test_the_installed_id_follows_from_the_manifest_key(self):
        key = base64.b64decode(json.loads((EXTENSION / 'manifest.json').read_text())['key'])
        ident = ''.join(chr(ord('a') + int(c, 16)) for c in hashlib.sha256(key).hexdigest()[:32])
        host = json.loads((HERE / 'com.caboose.webmcp.json').read_text())
        self.assertEqual(host['allowed_origins'], [f'chrome-extension://{ident}/'])
        self.assertEqual(host['path'], '/usr/lib/caboose/computer-use/webmcp/host.py')

    def test_the_manifest_names_files_that_exist(self):
        manifest = json.loads((EXTENSION / 'manifest.json').read_text())
        files = [manifest['background']['service_worker']] + [f for script in manifest['content_scripts'] for f in script['js']]
        for name in files:
            self.assertTrue((EXTENSION / name).is_file(), name)
        self.assertEqual({s.get('world', 'ISOLATED') for s in manifest['content_scripts']}, {'MAIN', 'ISOLATED'})


class Host(unittest.TestCase):
    def test_a_socket_request_reaches_the_browser_and_its_reply_comes_back(self):
        runtime = tempfile.mkdtemp()
        host = subprocess.Popen([sys.executable, str(HERE / 'host.py')], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                env=dict(os.environ, XDG_RUNTIME_DIR=runtime))
        path = pathlib.Path(runtime, 'caboose-webmcp', f'{os.getpid()}.sock')
        for _ in range(100):
            if path.exists(): break
            time.sleep(0.05)
        self.assertEqual(oct(path.stat().st_mode & 0o777), '0o600')
        client = socket.socket(socket.AF_UNIX); client.connect(str(path))
        client.sendall(b'{"op": "call", "name": "add", "args": {"a": 2}}\n')
        size = struct.unpack('=I', host.stdout.read(4))[0]
        request = json.loads(host.stdout.read(size))
        self.assertEqual((request['op'], request['name'], request['args']), ('call', 'add', {'a': 2}))
        reply = json.dumps({'id': request['id'], 'ok': True, 'result': {'content': [{'type': 'text', 'text': '3'}]}}).encode()
        host.stdin.write(struct.pack('=I', len(reply)) + reply); host.stdin.flush()
        answer = json.loads(client.makefile().readline())
        self.assertEqual(answer, {'ok': True, 'result': {'content': [{'type': 'text', 'text': '3'}]}})
        client.sendall(b'{"op": "delete"}\n')
        self.assertFalse(json.loads(client.makefile().readline())['ok'])
        client.close()
        host.stdin.close(); host.wait(5)
        self.assertFalse(path.exists(), 'the socket goes with the browser')


if __name__ == '__main__':
    unittest.main()
