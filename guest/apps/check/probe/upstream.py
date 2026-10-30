"""A server on the network for the runtime check's probe: it allows no cross-origin reads,
so only the app's network origin can read it. Serves /echo, /pixel.png and /tone.wav."""
import io
import json
import math
import struct
import sys
import wave
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def png():
    raw = b'\x00\xff\x00\x00'
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 1, 1, 8, 2, 0, 0, 0)) + \
        chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b'')


def tone(seconds=30, rate=22050):
    out = io.BytesIO()
    with wave.open(out, 'wb') as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(b''.join(struct.pack('<h', int(8000 * math.sin(2 * math.pi * 440 * i / rate)))
                               for i in range(seconds * rate)))
    return out.getvalue()


FILES = {'/pixel.png': ('image/png', png()), '/tone.wav': ('audio/wav', tone())}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def send(self, kind, body):
        self.send_response(200)
        self.send_header('Content-Type', kind)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path in FILES:
            return self.send(*FILES[self.path])
        self.echo()

    def echo(self):
        length = int(self.headers.get('Content-Length') or 0)
        body = self.rfile.read(length).decode() if length else ''
        self.send('application/json', json.dumps({'method': self.command, 'body': body,
                                                  'headers': {k.lower(): v for k, v in self.headers.items()}}).encode())

    do_POST = echo


ThreadingHTTPServer(('127.0.0.1', int(sys.argv[1])), Handler).serve_forever()
