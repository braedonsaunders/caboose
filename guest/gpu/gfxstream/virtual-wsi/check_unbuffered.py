#!/usr/bin/env python3
"""Private same-process Wayland/CGLS test with a deliberately fake executor."""
import argparse
import asyncio
import contextlib
import hashlib
import json
import os
from pathlib import Path
import secrets
import signal
import socket
import struct
import tempfile
import time

from live_protocol import Decoder, Envelope, Kind, encode

EXECUTOR = bytes.fromhex('00112233445566778899aabbccddeeff')
HELLO = b'CBGLREF1' + struct.pack('<II', 3, 0x30) + bytes.fromhex(
    '20d3bb2e30337cabf0febb006ed102ab25ccf6d9ddbfaf624c7e68f9040969c0')


def client_frame(payload):
    mask = secrets.token_bytes(4)
    size = len(payload)
    header = bytes((0x82, 0x80 | size)) if size < 126 else bytes((0x82, 0xfe)) + struct.pack('!H', size)
    return header + mask + bytes(value ^ mask[i % 4] for i, value in enumerate(payload))


async def stop(proc):
    if proc and proc.returncode is None:
        proc.terminate()
        try: await asyncio.wait_for(proc.wait(), 5)
        except asyncio.TimeoutError:
            proc.kill()
            await proc.wait()


async def main(args):
    output = Path(args.output)
    output.mkdir(mode=0o700, parents=True, exist_ok=True)
    hashes = {name: hashlib.sha256(Path(path).read_bytes()).hexdigest()
              for name, path in [('display', args.display), ('probe', args.probe), ('client', args.client)]}
    (output / 'manifest.json').write_text(json.dumps({'binaries': hashes, 'executor': 'fake'}) + '\n')
    with tempfile.TemporaryDirectory(prefix='caboose-virtual-window-', dir=args.scratch) as directory:
        root = Path(directory)
        os.chmod(root, 0o700)
        token = root / 'token'; token.write_text('private-fixture-token\n'); token.chmod(0o600)
        stream = root / 'stream.sock'; surface = root / 'surface.sock'
        env = dict(os.environ, XDG_RUNTIME_DIR=str(root), WAYLAND_DISPLAY='wayland-fixture', HOME=str(root))
        # Reserve an ephemeral loopback port only in this private network namespace.
        with socket.socket() as reservation:
            reservation.bind(('127.0.0.1', 0)); port = reservation.getsockname()[1]
        command = [args.display, '--listen', f'127.0.0.1:{port}', '--socket', 'wayland-fixture',
                   '--token-file', str(token), '--no-xwayland', '--no-audio', '--encoder', 'software',
                   '--private-gpu-stream-socket', str(stream), '--private-gpu-surface-socket', str(surface)]
        log = open(output / 'display.log', 'wb', buffering=0)
        compositor = probe = client = None
        reader = writer = None
        try:
            compositor = await asyncio.create_subprocess_exec(*command, env=env, stdout=log, stderr=log)
            deadline = time.monotonic() + 10
            while True:
                if compositor.returncode is not None: raise RuntimeError('compositor exited before listening')
                try: reader, writer = await asyncio.open_connection('127.0.0.1', port); break
                except OSError:
                    if time.monotonic() >= deadline: raise
                    await asyncio.sleep(.05)
            request = (b'GET /gpu HTTP/1.1\r\nHost: private\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n'
                       b'Authorization: Bearer private-fixture-token\r\nX-Caboose-GPU-Computer: fixture\r\n'
                       b'X-Caboose-GPU-Executor: 00112233-4455-6677-8899-aabbccddeeff\r\n'
                       b'Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n'
                       b'Sec-WebSocket-Protocol: caboose.gpu.live.v1\r\n\r\n')
            writer.write(request); await writer.drain()
            if not (await asyncio.wait_for(reader.readuntil(b'\r\n\r\n'), 5)).startswith(b'HTTP/1.1 101 '):
                raise RuntimeError('GPU admission failed')
            decoder = Decoder(EXECUTOR, 1)
            sequence = 1
            async def receive():
                header = await asyncio.wait_for(reader.readexactly(2), 10)
                if header[0] != 0x82 or header[1] & 128: raise RuntimeError('bad executor frame')
                n = header[1]
                if n == 126: n = struct.unpack('!H', await reader.readexactly(2))[0]
                elif n == 127: n = struct.unpack('!Q', await reader.readexactly(8))[0]
                frames = []; decoder.feed(await reader.readexactly(n), frames.append)
                if len(frames) != 1: raise RuntimeError('bad executor envelope')
                return frames[0]
            async def send(kind, process=0, stream_id=0, payload=b''):
                nonlocal sequence
                writer.write(client_frame(encode(Envelope(kind, EXECUTOR, 1, process, stream_id, sequence, payload))))
                sequence += 1
                await writer.drain()
            hello = await receive()
            if hello.kind != Kind.SESSION or hello.payload != HELLO: raise RuntimeError('wrong session hello')
            await send(Kind.SESSION_READY, payload=HELLO)
            deadline = time.monotonic() + 10
            while not stream.exists() or not surface.exists():
                if compositor.returncode is not None or time.monotonic() >= deadline: raise RuntimeError('GPU sockets unavailable')
                await asyncio.sleep(.05)
            probe = await asyncio.create_subprocess_exec(args.probe, '--url', f'ws://127.0.0.1:{port}/',
                '--token-file', str(token), '--display', '800x600@60x1', '--duration', '5', '--windows', '1', '--json',
                stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
            deadline = time.monotonic() + 5
            while 'session started' not in (output / 'display.log').read_text(errors='replace'):
                if probe.returncode is not None or time.monotonic() >= deadline: raise RuntimeError('owner display unavailable')
                await asyncio.sleep(.05)
            client = await asyncio.create_subprocess_exec(args.client, str(stream), str(surface), '123', env=env,
                stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
            frame = await receive()
            if frame.kind != Kind.PROCESS_OPEN: raise RuntimeError('missing real process association')
            process = frame.process; await send(Kind.PROCESS_READY, process)
            frame = await receive()
            if frame.kind != Kind.STREAM_OPEN or frame.process != process: raise RuntimeError('missing real stream association')
            await send(Kind.STREAM_READY, process, frame.stream)
            bound_window = None
            while bound_window is None:
                frame = await receive()
                if frame.kind == Kind.DATA:
                    if frame.payload != bytes(4): raise RuntimeError('unexpected guest stream bytes')
                elif frame.kind == Kind.SURFACE_BIND and frame.process == process:
                    bound_window = struct.unpack_from('<Q', frame.payload, 40)[0]
                    if not bound_window: raise RuntimeError('missing compositor window grant')
                    # This test executor has no Vulkan backend; only transport and
                    # real compositor-owned grant/announcement are under test.
                    await send(Kind.SURFACE_BOUND, process, payload=frame.payload[:40] + struct.pack('<iIiI', 0, 1, 0, 0))
                else: raise RuntimeError('unexpected fake executor control')
            lines = []
            while not (any(line.startswith('BOUND ') for line in lines) and
                       any(line.startswith('CONFIGURE ') and all(int(v) > 0 for v in line.split()[2:4]) for line in lines)):
                line = await asyncio.wait_for(client.stdout.readline(), 5)
                if not line: raise RuntimeError('Wayland fixture exited before bind')
                lines.append(line.decode().strip())
            bound = next(line for line in lines if line.startswith('BOUND ')).split()
            if int(bound[1]) != bound_window: raise RuntimeError('surface bind window mismatch')
            configs = [line.split() for line in lines if line.startswith('CONFIGURE ')]
            if not any(int(row[2]) > 0 and int(row[3]) > 0 for row in configs):
                raise RuntimeError('no positive xdg configure before bind')
            stdout, stderr = await asyncio.wait_for(probe.communicate(), 10)
            (output / 'probe.stdout').write_bytes(stdout)
            (output / 'probe.stderr').write_bytes(stderr)
            if probe.returncode: raise RuntimeError('owner probe failed: ' + stderr.decode(errors='replace'))
            report = json.loads(stdout.decode().strip().splitlines()[-1])
            matches = [w for w in report['windows'] if w['id'] == bound_window]
            if len(matches) != 1 or matches[0]['geometry'][2:] != [800, 600] or matches[0]['frames'] != 0:
                raise RuntimeError('unbuffered WindowCreate mismatch: ' + repr(matches))
            # Only the exact child of our compositor is signalled.
            children = Path(f'/proc/{compositor.pid}/task/{compositor.pid}/children').read_text().split()
            brokers = [int(pid) for pid in children if b'caboose-gpu-broker' in Path(f'/proc/{pid}/cmdline').read_bytes()]
            if len(brokers) != 1: raise RuntimeError('owned broker child not uniquely identified')
            os.kill(brokers[0], signal.SIGTERM)
            await asyncio.wait_for(reader.read(), 5)
            reconnect = await asyncio.create_subprocess_exec(args.probe, '--url', f'ws://127.0.0.1:{port}/',
                '--token-file', str(token), '--check', stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
            out, err = await asyncio.wait_for(reconnect.communicate(), 10)
            if reconnect.returncode: raise RuntimeError('ordinary display reconnect failed: ' + err.decode(errors='replace'))
            result = {'status': 'PASS', 'executor': 'fake', 'window': bound_window,
                      'geometry': matches[0]['geometry'], 'frames': matches[0]['frames'],
                      'configure': configs, 'reconnect': out.decode(errors='replace').strip()}
            (output / 'result.json').write_text(json.dumps(result) + '\n')
            print(json.dumps(result))
        except Exception as error:
            (output / 'result.json').write_text(json.dumps({'status': 'FAIL', 'error': str(error)}) + '\n')
            raise
        finally:
            if writer:
                writer.close()
                with contextlib.suppress(OSError, asyncio.TimeoutError): await asyncio.wait_for(writer.wait_closed(), 2)
            await stop(client); await stop(probe); await stop(compositor)
            log.close()


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--display', required=True)
    parser.add_argument('--probe', required=True)
    parser.add_argument('--client', required=True)
    parser.add_argument('--scratch', required=True)
    parser.add_argument('--output', required=True)
    asyncio.run(main(parser.parse_args()))
