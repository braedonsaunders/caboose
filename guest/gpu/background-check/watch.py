#!/usr/bin/env python3
"""Watch media continuity in Chromium while the phone leaves and returns (README.md).

watch.py --cdp http://127.0.0.1:9222 [--seconds 120] [--out timeline.jsonl]
         [--broker-log PATH] [--expect-gpu-restarts N]

Opens media.html in a new tab of the running Chromium, starts its video and tone with a
CDP click, then samples the page and Chromium's GPU process every 250 ms until --seconds
pass. Meanwhile the phone app goes to the background and comes back. Prints a JSON
verdict and exits 0 only on PASS. Python 3 standard library only.
"""
import argparse
import base64
import functools
import http.server
import json
import os
import pathlib
import socket
import struct
import sys
import threading
import time
import urllib.parse
import urllib.request

HERE = pathlib.Path(__file__).resolve().parent
SAMPLE_SECONDS = 0.25
VIDEO_STALL_LIMIT = 1.0   # longest wall-clock time the video may stand still
AUDIO_STALL_LIMIT = 0.5   # longest wall-clock time the audio clock may stand still
FRAME_STALL_LIMIT = 1.0   # longest time without a requestAnimationFrame


class CDP:
    """A minimal synchronous CDP client over one WebSocket (RFC 6455, client side)."""

    def __init__(self, url):
        parts = urllib.parse.urlsplit(url)
        self.sock = socket.create_connection((parts.hostname, parts.port or 80), timeout=10)
        key = base64.b64encode(os.urandom(16)).decode()
        path = parts.path + (f'?{parts.query}' if parts.query else '')
        self.sock.sendall((f'GET {path} HTTP/1.1\r\nHost: {parts.netloc}\r\nUpgrade: websocket\r\n'
                           f'Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\n'
                           'Sec-WebSocket-Version: 13\r\n\r\n').encode())
        response = b''
        while b'\r\n\r\n' not in response:
            chunk = self.sock.recv(4096)
            if not chunk: raise ConnectionError('CDP handshake closed')
            response += chunk
        head, self.buffer = response.split(b'\r\n\r\n', 1)
        if b' 101 ' not in head.split(b'\r\n', 1)[0]: raise ConnectionError(head.split(b'\r\n', 1)[0].decode())
        self.next_id = 0

    def _send(self, text):
        payload = text.encode()
        mask = os.urandom(4)
        n = len(payload)
        header = bytes([0x81]) + (bytes([0x80 | n]) if n < 126 else
                                  bytes([0x80 | 126]) + struct.pack('!H', n) if n < 65536 else
                                  bytes([0x80 | 127]) + struct.pack('!Q', n))
        self.sock.sendall(header + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(payload)))

    def _read(self, count):
        while len(self.buffer) < count:
            chunk = self.sock.recv(65536)
            if not chunk: raise ConnectionError('CDP connection closed')
            self.buffer += chunk
        data, self.buffer = self.buffer[:count], self.buffer[count:]
        return data

    def _message(self):
        message = b''
        while True:
            first, second = self._read(2)
            n = second & 0x7f
            if n == 126: n = struct.unpack('!H', self._read(2))[0]
            elif n == 127: n = struct.unpack('!Q', self._read(8))[0]
            payload = self._read(n)
            opcode = first & 0x0f
            if opcode == 8: raise ConnectionError('CDP closed')
            if opcode in (9, 10): continue
            message += payload
            if first & 0x80: return json.loads(message)

    def call(self, method, **params):
        self.next_id += 1
        ident = self.next_id
        self._send(json.dumps({'id': ident, 'method': method, 'params': params}))
        while True:
            reply = self._message()
            if reply.get('id') == ident:
                if 'error' in reply: raise RuntimeError(f"{method}: {reply['error']}")
                return reply.get('result', {})


def serve_fixture():
    """Serves this directory (media.html, clip.webm) on a loopback port; returns the base URL."""
    class Quiet(http.server.SimpleHTTPRequestHandler):
        def log_message(self, *args): pass
    handler = functools.partial(Quiet, directory=str(HERE))
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return f'http://127.0.0.1:{server.server_address[1]}/'


def gpu_pids(browser):
    info = browser.call('SystemInfo.getProcessInfo')
    return sorted(p['id'] for p in info.get('processInfo', []) if p.get('type') == 'GPU')


def log_size(path):
    try: return path.stat().st_size
    except OSError: return None


def presents_after(path, offset):
    """Presents the broker logged after byte `offset` of its log (CABOOSE_GPU_PRESENT_RATE)."""
    total = 0
    try:
        with open(path, 'rb') as log:
            log.seek(offset or 0)
            for line in log.read().decode(errors='replace').splitlines():
                if 'CABOOSE_GPU_PRESENT_RATE' not in line: continue
                fields = dict(part.split('=', 1) for part in line.split() if '=' in part)
                total += int(fields.get('presented', 0))
    except (OSError, ValueError):
        return None
    return total


def stall(samples, key):
    """Longest wall-clock interval over which samples[key] did not increase."""
    longest, still_since, last = 0.0, None, None
    for sample in samples:
        value = sample[key]
        if last is not None and value <= last:
            still_since = still_since if still_since is not None else previous
            longest = max(longest, sample['t'] - still_since)
        else:
            still_since = None
        last, previous = value, sample['t']
    return longest


def verdict(samples, expect_gpu_restarts=0, presents=None):
    """PASS/FAIL and reasons for a sampled timeline (pure; unit-tested)."""
    reasons = []
    if len(samples) < 8: return {'result': 'FAIL', 'reasons': ['too few samples']}
    if len({s['timeOrigin'] for s in samples}) != 1: reasons.append('the page reloaded')
    if any(s['paused'] or s['ended'] or s['error'] for s in samples): reasons.append('the video paused, ended or failed')
    if any(s['audioState'] != 'running' for s in samples): reasons.append('the audio context left the running state')
    video, audio, frames = stall(samples, 'videoTime'), stall(samples, 'audioTime'), stall(samples, 'frames')
    if video > VIDEO_STALL_LIMIT: reasons.append(f'the video stood still for {video:.2f} s')
    if audio > AUDIO_STALL_LIMIT: reasons.append(f'the audio clock stood still for {audio:.2f} s')
    if frames > FRAME_STALL_LIMIT: reasons.append(f'no frame was painted for {frames:.2f} s')
    pids = []
    for sample in samples:
        if sample['gpu'] and (not pids or pids[-1] != sample['gpu']): pids.append(sample['gpu'])
    restarts = max(0, len(pids) - 1)
    if restarts < expect_gpu_restarts: reasons.append(f'{restarts} GPU process restarts, expected {expect_gpu_restarts}')
    last_change = next((s['t'] for s in reversed(samples) if s['gpu'] != samples[-1]['gpu']), samples[0]['t'])
    after = [s for s in samples if s['t'] > last_change]
    if len(after) >= 2 and after[-1]['decodedFrames'] <= after[0]['decodedFrames']:
        reasons.append('no video frame was decoded after the last GPU process change')
    if presents is not None and presents == 0: reasons.append('the broker logged no presents after the last GPU process change')
    return {'result': 'FAIL' if reasons else 'PASS', 'reasons': reasons, 'gpu_restarts': restarts,
            'video_stall_s': round(video, 3), 'audio_stall_s': round(audio, 3), 'frame_stall_s': round(frames, 3),
            'decoded_frames': samples[-1]['decodedFrames'], 'dropped_frames': samples[-1]['droppedFrames']}


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    ap.add_argument('--cdp', default='http://127.0.0.1:9222')
    ap.add_argument('--seconds', type=float, default=120)
    ap.add_argument('--out', type=pathlib.Path)
    ap.add_argument('--broker-log', type=pathlib.Path)
    ap.add_argument('--expect-gpu-restarts', type=int, default=0)
    args = ap.parse_args(argv)
    if not (HERE / 'clip.webm').is_file(): ap.error('run make-media.sh first')
    base = serve_fixture()
    version = json.load(urllib.request.urlopen(f'{args.cdp}/json/version', timeout=5))
    browser = CDP(version['webSocketDebuggerUrl'])
    target = browser.call('Target.createTarget', url=base + 'media.html')['targetId']
    page_url = next(t['webSocketDebuggerUrl'] for t in json.load(urllib.request.urlopen(f'{args.cdp}/json/list', timeout=5))
                    if t['id'] == target)
    page = CDP(page_url)
    deadline = time.monotonic() + 15
    while not page.call('Runtime.evaluate', expression='typeof mediaState === "function"', returnByValue=True)['result'].get('value'):
        if time.monotonic() > deadline: raise TimeoutError('media.html did not load')
        time.sleep(0.1)
    for kind in ('mousePressed', 'mouseReleased'):
        page.call('Input.dispatchMouseEvent', type=kind, x=20, y=20, button='left', clickCount=1)
    samples, started = [], time.monotonic()
    out = args.out.open('w') if args.out else None
    print('watching: background the phone app, then bring it back', file=sys.stderr, flush=True)
    while time.monotonic() - started < args.seconds:
        state = page.call('Runtime.evaluate', expression='mediaState()', returnByValue=True)['result']['value']
        pids = gpu_pids(browser)
        sample = dict(state, t=time.monotonic(), gpu=pids[0] if pids else 0,
                      broker_offset=log_size(args.broker_log) if args.broker_log else None)
        playing = state['started'] and state['videoTime'] > 0 and state['audioTime'] > 0
        if not playing and not samples: started = time.monotonic()  # playback has not begun yet
        else: samples.append(sample)
        if out: out.write(json.dumps(sample) + '\n'); out.flush()
        time.sleep(SAMPLE_SECONDS)
    if not samples: raise RuntimeError('playback never started')
    # Presents logged since the first sample on the final GPU process.
    first_final = next(s for s in samples if s['gpu'] == samples[-1]['gpu']
                       and all(later['gpu'] == s['gpu'] for later in samples[samples.index(s):]))
    presents = presents_after(args.broker_log, first_final['broker_offset']) if args.broker_log else None
    result = verdict(samples, args.expect_gpu_restarts, presents)
    browser.call('Target.closeTarget', targetId=target)
    print(json.dumps(result, indent=2))
    return 0 if result['result'] == 'PASS' else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
