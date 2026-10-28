#!/usr/bin/env python3
"""Exercise the private service in Linux, including real inotify and dirfd confinement."""
import http.client
import importlib.util
import json
import os
import tempfile
import threading
import time

with tempfile.TemporaryDirectory() as root:
    token = os.path.join(root, 'token')
    home = os.path.join(root, 'home')
    os.mkdir(home)
    with open(token, 'w') as f: f.write('test-token')
    os.environ['CABOOSE_FILES_ROOT'] = home
    os.environ['CABOOSE_FILES_TOKEN_FILE'] = token
    spec = importlib.util.spec_from_file_location('files', os.path.join(os.path.dirname(__file__), 'caboose-files.py'))
    service = importlib.util.module_from_spec(spec); spec.loader.exec_module(service)
    service.changes = service.Changes()
    server = service.ThreadingHTTPServer(('127.0.0.1', 0), service.Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    def request(method, path, data=None, headers=None):
        connection = http.client.HTTPConnection('127.0.0.1', server.server_port, timeout=5)
        connection.request(method, path, body=data, headers={'Authorization': 'Bearer test-token', **(headers or {})})
        response = connection.getresponse(); body = response.read(); result = (response.status, dict(response.getheaders()), body)
        connection.close(); return result
    try:
        assert request('GET', '/stat?path=../etc')[0] == 400
        os.symlink('/etc', os.path.join(home, 'escape'))
        assert request('GET', '/list?path=escape')[0] in (400, 403, 500)
        assert request('PUT', '/content?path=escape/caboose-check', b'no', {'If-None-Match': '*'})[0] in (400, 403, 500)
        anchor = json.loads(request('GET', '/changes')[2])['anchor']
        assert request('POST', '/mkdir?path=Documents')[0] == 201
        for _ in range(50):
            result = json.loads(request('GET', '/changes?anchor=' + anchor)[2])
            if result['changed']: break
            time.sleep(.02)
        assert result['changed'] and any(e['path'] == 'Documents' for e in result['events'])
        status, _, body = request('PUT', '/content?path=Documents/a.txt', b'abcdef', {'If-None-Match': '*'})
        assert status == 201
        etag = json.loads(body)['etag']
        chunked = http.client.HTTPConnection('127.0.0.1', server.server_port, timeout=5)
        chunked.request('PUT', '/content?path=Documents/chunked', body=iter([b'abc', b'def']),
                        headers={'Authorization': 'Bearer test-token', 'If-None-Match': '*'}, encode_chunked=True)
        response = chunked.getresponse(); assert response.status == 201; response.read(); chunked.close()
        assert request('GET', '/content?path=Documents/chunked')[2] == b'abcdef'
        status, headers, body = request('GET', '/content?path=Documents/a.txt', headers={'Range': 'bytes=1-3'})
        assert status == 206 and body == b'bcd' and headers['Content-Range'] == 'bytes 1-3/6'
        assert request('GET', '/content?path=Documents/a.txt', headers={'Range': 'bytes=99-'})[0] == 416
        assert request('GET', '/content?path=Documents/a.txt', headers={'If-Match': '"wrong"'})[0] == 412
        assert request('PUT', '/content?path=Documents/a.txt', b'new', {'If-Match': '"wrong"'})[0] == 412
        status, _, body = request('PUT', '/content?path=Documents/a.txt', b'new', {'If-Match': etag})
        assert status == 200
        etag = json.loads(body)['etag']
        assert request('DELETE', '/item?path=Documents/a.txt', headers={'If-Match': '"wrong"'})[0] == 412
        status, _, body = request('POST', '/move?path=Documents/a.txt', json.dumps({'destination': 'Documents/b.txt'}), {'Content-Type': 'application/json', 'If-Match': etag})
        assert status == 200, (status, body)
        assert request('DELETE', '/item?path=Documents/b.txt')[0] == 200
        assert request('GET', '/stat?path=Documents/b.txt')[0] == 404
        assert os.listdir(os.path.join(home, '.local/share/Trash/files'))
        print('guest file service checks passed')
    finally:
        server.shutdown(); server.server_close()
