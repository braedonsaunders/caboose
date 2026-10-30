#!/usr/bin/env python3
"""Local fake host for the simulator-only WKWebView handoff check."""
import io
import json
import math
import struct
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from threading import Lock

PAGE = b'<!doctype html><title>handoff check</title>'


def tone(seconds=20, rate=22050):
    out = io.BytesIO()
    with wave.open(out, 'wb') as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(b''.join(struct.pack('<h', int(4000 * math.sin(2 * math.pi * 440 * i / rate)))
                               for i in range(seconds * rate)))
    return out.getvalue()


# A server elsewhere on the network, with no CORS consent: only the app's network origin reads it.
TONE = tone()
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
        if self.path == '/upstream/tone.wav':
            return self.answer(TONE, content_type='audio/wav')
        if self.path == '/upstream/echo':
            return self.echo('')
        self.answer({}, 404)
    def echo(self, body):
        return self.answer({'method': self.command, 'body': body, 'headers': {k.lower(): v for k, v in self.headers.items()}})
    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get('Content-Length') or 0))
        if self.path == '/upstream/echo':
            return self.echo(raw.decode())
        body = json.loads(raw)
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
                value = {'id':'check', 'name':'Check', 'capabilities': ['exec', 'files', 'net', 'media']}
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
