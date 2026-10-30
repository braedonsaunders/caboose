"""net: the network origin's rules, and requests through it to a local server with curl.

    python3 -m unittest discover -s guest/apps -p 'test_*.py'
"""

import http.client
import io
import json
import os
import shutil
import sys
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import net  # noqa: E402

TOKEN = 'ab' * 16


class Rules(unittest.TestCase):
    def test_target(self):
        self.assertEqual(net.target(f'/{TOKEN}/https/api.example.com/v1/items?q=a%20b&n=1', TOKEN),
                         'https://api.example.com/v1/items?q=a%20b&n=1')
        self.assertEqual(net.target(f'/{TOKEN}/http/radio.example%3A8000/live', TOKEN), 'http://radio.example:8000/live')
        self.assertEqual(net.target(f'/{TOKEN}/http/%5B%3A%3A1%5D%3A8080', TOKEN), 'http://[::1]:8080/')
        self.assertEqual(net.target(f'/{TOKEN}/HTTPS/a.example/', TOKEN), 'https://a.example/')

    def test_target_refusals(self):
        cases = {
            f'/{"cd" * 16}/https/a.example/': 404,
            f'/{TOKEN}/https': 404,
            f'/{TOKEN}/ftp/a.example/x': 400,
            f'/{TOKEN}/file/a.example/etc/passwd': 400,
            f'/{TOKEN}/https/user%40a.example/': 400,
            f'/{TOKEN}/https/a.example%2Fb/': 400,
            f'/{TOKEN}/https/a.example:99999/': 400,
            f'/{TOKEN}/https//x': 400,
            'relative': 400,
        }
        for path, status in cases.items():
            with self.subTest(path=path):
                with self.assertRaises(net.NetError) as caught:
                    net.target(path, TOKEN)
                self.assertEqual(caught.exception.status, status)

    def test_upstream_headers(self):
        sent = net.upstream_headers([
            ('Host', '127.0.0.1:1'), ('Origin', 'caboose-app://radio'), ('Authorization', 'Bearer k'),
            ('Range', 'bytes=0-'), ('Sec-Fetch-Mode', 'cors'), ('Accept-Encoding', 'gzip'),
            ('X-Caboose-Header-User-Agent', 'VLC/3.0'), ('User-Agent', 'WebKit'), ('X-Caboose-Header-Cookie', 'a=1'),
            ('X-Caboose-Header-Host', 'evil.example'), ('Icy-MetaData', '1'), ('X-Bad', 'a\r\nInjected: 1'),
        ])
        self.assertEqual(sent, [('Authorization', 'Bearer k'), ('Range', 'bytes=0-'), ('Icy-MetaData', '1'),
                                ('User-Agent', 'VLC/3.0'), ('Cookie', 'a=1')])

    def test_origins_and_response_headers(self):
        self.assertEqual(net.allowed_origin(None, 'caboose-app://radio'), '*')
        self.assertEqual(net.allowed_origin('caboose-app://radio', 'caboose-app://radio'), 'caboose-app://radio')
        self.assertIsNone(net.allowed_origin('https://evil.example', 'caboose-app://radio'))
        headers = net.response_headers([('Content-Type', 'audio/mpeg'), ('Content-Length', '10'), ('Set-Cookie', 's=1'),
                                        ('Access-Control-Allow-Origin', 'https://site.example'),
                                        ('Content-Security-Policy', "default-src 'none'"), ('icy-name', 'Radio')],
                                       'caboose-app://radio', 'https://a.example/x')
        self.assertEqual(headers, [('Content-Type', 'audio/mpeg'), ('Content-Length', '10'), ('X-Caboose-Set-Cookie', 's=1'),
                                   ('icy-name', 'Radio'), ('Access-Control-Allow-Origin', 'caboose-app://radio'),
                                   ('Access-Control-Expose-Headers', '*'), ('Vary', 'Origin'),
                                   ('X-Caboose-Url', 'https://a.example/x')])
        decoded = net.response_headers([('Content-Encoding', 'gzip'), ('Content-Length', '4')], '*', 'https://a.example/')
        self.assertNotIn('Content-Length', [name for name, _ in decoded])

    def test_read_head_skips_interim_and_redirects(self):
        dumped = (b'HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 302 Found\r\nLocation: /next\r\n\r\n'
                  b'HTTP/2 200\r\ncontent-type: text/plain\r\n\r\nbody')
        stream = io.BufferedReader(io.BytesIO(dumped))
        status, reason, fields, moved = net.read_head(stream)
        self.assertEqual((status, reason, fields, moved), (200, '', [('content-type', 'text/plain')], '/next'))
        self.assertEqual(stream.read(), b'body')
        icy = net.read_head(io.BufferedReader(io.BytesIO(b'ICY 200 OK\r\nicy-name: Radio\r\n\r\n')))
        self.assertEqual(icy[:3], (200, 'OK', [('icy-name', 'Radio')]))

    def test_curl_config_quotes(self):
        config = net.curl_config('https://a.example/"x"', 'PUT', [('Authorization', 'a\\b"c')], True)
        self.assertIn('url = "https://a.example/\\"x\\""', config)
        self.assertIn('request = "PUT"', config)
        self.assertIn('header = "Authorization: a\\\\b\\"c"', config)
        self.assertIn('header = "Content-Type:"', config)
        self.assertNotIn('request', net.curl_config('https://a.example/', 'POST', [('Content-Type', 'text/plain')], True))


class Upstream(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *_):
        pass

    def reply(self, status, body, headers=()):
        self.send_response(status)
        for name, value in headers:
            self.send_header(name, value)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        if self.command != 'HEAD':
            self.wfile.write(body)

    def echo(self):
        length = int(self.headers.get('Content-Length') or 0)
        body = self.rfile.read(length) if length else b''
        self.reply(200, json.dumps({'method': self.command, 'path': self.path, 'body': body.decode(),
                                    'headers': {k.lower(): v for k, v in self.headers.items()}}).encode(),
                   [('Content-Type', 'application/json'), ('Set-Cookie', 'session=1'),
                    ('Access-Control-Allow-Origin', 'https://elsewhere.example')])

    def do_GET(self):
        if self.path == '/moved':
            return self.reply(302, b'', [('Location', '/echo?after=1')])
        if self.path == '/stream':
            self.send_response(200)
            self.send_header('Content-Type', 'audio/mpeg')
            self.send_header('Connection', 'close')
            self.end_headers()
            for _ in range(4):
                self.wfile.write(b'\xff\xfb' * 512)
                self.wfile.flush()
            return
        self.echo()

    do_POST = do_PUT = do_DELETE = do_HEAD = echo


@unittest.skipUnless(shutil.which('curl'), 'needs curl')
class Through(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.upstream = ThreadingHTTPServer(('127.0.0.1', 0), Upstream)
        cls.upstream.daemon_threads = True
        threading.Thread(target=cls.upstream.serve_forever, daemon=True).start()
        cls.authority = f'127.0.0.1%3A{cls.upstream.server_address[1]}'
        cls.origin = net.NetOrigin('caboose-app://radio')

    @classmethod
    def tearDownClass(cls):
        cls.origin.close()
        cls.upstream.shutdown()
        cls.upstream.server_close()

    def request(self, method, path, body=None, headers=None, token=None):
        connection = http.client.HTTPConnection('127.0.0.1', self.origin.server.server_address[1], timeout=10)
        connection.request(method, f'/{token or self.origin.token}/{path}', body=body, headers=headers or {})
        response = connection.getresponse()
        data = response.read()
        connection.close()
        return response, data

    def test_get_with_page_headers(self):
        response, data = self.request('GET', f'http/{self.authority}/echo?a=1', headers={
            'Origin': 'caboose-app://radio', 'Authorization': 'Bearer k', 'X-Caboose-Header-User-Agent': 'VLC/3.0',
            'X-Caboose-Header-Cookie': 'a=1', 'Cookie': 'webkit=1'})
        self.assertEqual(response.status, 200)
        echoed = json.loads(data)
        self.assertEqual(echoed['path'], '/echo?a=1')
        self.assertEqual(echoed['headers']['authorization'], 'Bearer k')
        self.assertEqual(echoed['headers']['user-agent'], 'VLC/3.0')
        self.assertEqual(echoed['headers']['cookie'], 'a=1')
        self.assertNotIn('origin', echoed['headers'])
        self.assertEqual(response.getheader('Access-Control-Allow-Origin'), 'caboose-app://radio')
        self.assertEqual(response.getheader('X-Caboose-Set-Cookie'), 'session=1')
        self.assertIsNone(response.getheader('Set-Cookie'))

    def test_post_body_and_methods(self):
        response, data = self.request('POST', f'http/{self.authority}/echo', body=b'{"x":1}',
                                      headers={'Content-Type': 'application/json'})
        echoed = json.loads(data)
        self.assertEqual((echoed['method'], echoed['body'], echoed['headers']['content-type']),
                         ('POST', '{"x":1}', 'application/json'))
        response, data = self.request('PUT', f'http/{self.authority}/echo', body=b'raw')
        echoed = json.loads(data)
        self.assertEqual((echoed['method'], echoed['body']), ('PUT', 'raw'))
        self.assertNotIn('content-type', echoed['headers'])
        response, data = self.request('DELETE', f'http/{self.authority}/echo')
        self.assertEqual(json.loads(data)['method'], 'DELETE')

    def test_redirect_and_final_url(self):
        response, data = self.request('GET', f'http/{self.authority}/moved')
        self.assertEqual(response.status, 200)
        self.assertEqual(json.loads(data)['path'], '/echo?after=1')
        self.assertTrue(response.getheader('X-Caboose-Url').endswith('/echo?after=1'))

    def test_streamed_body(self):
        response, data = self.request('GET', f'http/{self.authority}/stream')
        self.assertEqual((response.status, response.getheader('Content-Type'), len(data)), (200, 'audio/mpeg', 4096))

    def test_preflight(self):
        response, _ = self.request('OPTIONS', f'https/api.example/x', headers={
            'Origin': 'caboose-app://radio', 'Access-Control-Request-Method': 'PUT',
            'Access-Control-Request-Headers': 'authorization, x-caboose-header-cookie'})
        self.assertEqual(response.status, 204)
        self.assertEqual(response.getheader('Access-Control-Allow-Methods'), 'PUT')
        self.assertEqual(response.getheader('Access-Control-Allow-Headers'), 'authorization, x-caboose-header-cookie')

    def test_refusals(self):
        response, _ = self.request('GET', f'http/{self.authority}/echo', headers={'Origin': 'https://evil.example'})
        self.assertEqual(response.status, 403)
        response, _ = self.request('GET', f'http/{self.authority}/echo', token='cd' * 16)
        self.assertEqual(response.status, 404)
        response, _ = self.request('GET', 'http/127.0.0.1%3A9/unreachable')
        self.assertEqual(response.status, 502)
        self.assertTrue(response.getheader('X-Caboose-Error'))


if __name__ == '__main__':
    unittest.main()
