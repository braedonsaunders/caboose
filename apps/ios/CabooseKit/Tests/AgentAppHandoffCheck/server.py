#!/usr/bin/env python3
"""Local fake host for the simulator-only WKWebView handoff check."""
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from threading import Lock

PAGE = b'<!doctype html><title>handoff check</title>'
lock = Lock()
state = {'revision': -1, 'document': None, 'grant': 'a' * 32, 'log': []}

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def answer(self, value, status=200, content_type='application/json'):
        data = value if isinstance(value, bytes) else json.dumps(value).encode()
        self.send_response(status)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)
    def do_GET(self):
        if self.path.startswith('/v1/fs/stat'):
            return self.answer({'name':'index.html', 'kind':'file', 'size':len(PAGE), 'etag':''})
        if self.path.startswith('/v1/fs/content'):
            return self.answer(PAGE, content_type='text/html')
        if self.path == '/test/state':
            with lock: return self.answer(state)
        self.answer({}, 404)
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        with lock:
            if self.path == '/test/takeover':
                state.update(grant='b' * 32, revision=-1, document=None)
                return self.answer({'ok': True})
            state['log'].append(body)
            op, doc = body.get('operation'), body.get('document')
            if body.get('grant') != state['grant']:
                return self.answer({'ok':False, 'error':'This app is not handed off'})
            if op == 'open':
                revision = body['revision']
                if revision < state['revision'] or (revision == state['revision'] and doc != state['document']):
                    return self.answer({'ok':False, 'error':'This page has been replaced'})
                state.update(revision=revision, document=doc)
                value = {'id':'check', 'name':'Check'}
            elif doc != state['document']:
                return self.answer({'ok':False, 'error':'This page has been replaced'})
            elif op == 'close':
                state['document'] = None
                value = True
            elif op == 'events': value = []
            elif op == 'call':
                method = body.get('method')
                if method == 'files.read': value = 'aGVsbG8='
                elif method == 'exec': value = {'stdout':'ran', 'stderr':'', 'code':0}
                else: value = True
            else: return self.answer({'ok':False, 'error':'unknown'})
            self.answer({'ok':True, 'value':value})

ThreadingHTTPServer(('127.0.0.1', 18765), Handler).serve_forever()
