#!/usr/bin/env python3
"""Private fake-executor transport check; it does not issue Vulkan commands."""
import array
import asyncio
from contextlib import suppress
import os
from pathlib import Path
import socket
import struct
import sys
import tempfile

from live_protocol import Decoder, Envelope, Kind, encode
from test_gpu_websocket import client_frame
import control_protocol

HELLO = (b'CBGLREF1' + bytes((3, 0, 0, 0, 48, 0, 0, 0)) + bytes.fromhex(
    '20d3bb2e30337cabf0febb006ed102ab25ccf6d9ddbfaf624c7e68f9040969c0'))
EXECUTOR = bytes.fromhex('00112233445566778899aabbccddeeff')


async def main():
    draining = '--drain' in sys.argv[1:]
    with tempfile.TemporaryDirectory(prefix='gpu-loopback-', dir=os.environ['GPU_TRIAL_DIR']) as d:
        root = Path(d); token = root / 'token'; token.write_bytes(b'test-token')
        path = root / 'gpu.sock'
        parent, child = socket.socketpair(type=socket.SOCK_SEQPACKET)
        proc = await asyncio.create_subprocess_exec(
            sys.executable, str(Path(__file__).with_name('caboose-gpu-broker')),
            '--control-fd=0', '--token-file', str(token), '--socket', str(path),
            stdin=child, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
        child.close()
        listener = socket.socket(); listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.bind(('127.0.0.1', 0)); listener.listen(1)
        phone = socket.socket(); phone.connect(listener.getsockname())
        accepted, _ = listener.accept(); listener.close()
        parent.sendmsg([b'G'], [(socket.SOL_SOCKET, socket.SCM_RIGHTS, array.array('i', [accepted.fileno()]))])
        accepted.close(); phone.setblocking(False); parent.setblocking(False)
        phone_reader, phone_writer = await asyncio.open_connection(sock=phone)
        decoder = Decoder(EXECUTOR, 1); incoming_sequence = 1
        async def receive(expected):
            header = await asyncio.wait_for(phone_reader.readexactly(2), 5)
            if header[0] != 0x82 or header[1] & 128: raise RuntimeError('invalid server frame')
            n = header[1]
            if n == 126: n = struct.unpack('!H', await phone_reader.readexactly(2))[0]
            elif n == 127: n = struct.unpack('!Q', await phone_reader.readexactly(8))[0]
            frames = []; decoder.feed(await phone_reader.readexactly(n), frames.append)
            if len(frames) != 1 or frames[0].kind != expected: raise RuntimeError('unexpected envelope')
            return frames[0]
        async def send(kind, process=0, stream=0, payload=b''):
            nonlocal incoming_sequence
            data = encode(Envelope(kind, EXECUTOR, 1, process, stream, incoming_sequence, payload))
            incoming_sequence += 1
            phone_writer.write(client_frame(2, data)); await phone_writer.drain()
        local_writer = None
        try:
            request = (b'GET /gpu HTTP/1.1\r\nHost: guest\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n'
                       b'Authorization: Bearer test-token\r\nX-Caboose-GPU-Computer: test\r\n'
                       b'X-Caboose-GPU-Executor: 00112233-4455-6677-8899-aabbccddeeff\r\n'
                       b'Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n'
                       b'Sec-WebSocket-Protocol: caboose.gpu.live.v1\r\n\r\n')
            phone_writer.write(request); await phone_writer.drain()
            response = await asyncio.wait_for(phone_reader.readuntil(b'\r\n\r\n'), 5)
            if not response.startswith(b'HTTP/1.1 101 '): raise RuntimeError('upgrade failed')
            first = await receive(Kind.SESSION)
            if first.payload != HELLO: raise RuntimeError('session hello mismatch')
            await send(Kind.SESSION_READY, payload=HELLO)
            ready_record = await asyncio.wait_for(asyncio.get_running_loop().sock_recv(parent, 80), 5)
            if control_protocol.decode(ready_record, 0) != control_protocol.ExecutorLifecycle(4, EXECUTOR, 1):
                raise RuntimeError('missing actual session-ready control')
            for _ in range(100):
                if path.exists(): break
                await asyncio.sleep(.02)
            if not path.exists(): raise RuntimeError('local socket not ready')
            local_reader, local_writer = await asyncio.open_unix_connection(str(path))
            local_writer.write(HELLO); await local_writer.drain()
            process = await receive(Kind.PROCESS_OPEN)
            await send(Kind.PROCESS_READY, process=process.process)
            stream = await receive(Kind.STREAM_OPEN)
            await send(Kind.STREAM_READY, process=process.process, stream=stream.stream)
            if await asyncio.wait_for(local_reader.readexactly(48), 5) != HELLO: raise RuntimeError('local hello mismatch')
            local_writer.write(b'guest-wire'); await local_writer.drain()
            data = await receive(Kind.DATA)
            if data.payload != b'guest-wire': raise RuntimeError('guest bytes changed')
            await send(Kind.DATA, process=process.process, stream=stream.stream, payload=b'executor-reply')
            if await asyncio.wait_for(local_reader.readexactly(14), 5) != b'executor-reply': raise RuntimeError('reply changed')
            if draining:
                # Explicit phone drain cancels active device work; native
                # retirement and revoke acknowledgements remain mandatory.
                await send(Kind.EXECUTOR_DRAIN)
                lost_record = await asyncio.wait_for(asyncio.get_running_loop().sock_recv(parent, 80), 5)
                if control_protocol.decode(lost_record, 0) != control_protocol.ExecutorLifecycle(5, EXECUTOR, 1):
                    raise RuntimeError('missing drain-lost control')
                stopped = await receive(Kind.PROCESS_STOP)
                await send(Kind.DATA, process=process.process, stream=stream.stream, payload=b'discarded-during-drain')
                await send(Kind.FIN, process=process.process, stream=stream.stream)
                await send(Kind.PROCESS_RETIRED, process=stopped.process)
                await receive(Kind.REVOKE); await send(Kind.REVOKED)
                retired_record = await asyncio.wait_for(asyncio.get_running_loop().sock_recv(parent, 80), 5)
                if control_protocol.decode(retired_record, 0) != control_protocol.ExecutorLifecycle(6, EXECUTOR, 1):
                    raise RuntimeError('missing native-retired control')
                if await asyncio.wait_for(local_reader.read(), 5) != b'': raise RuntimeError('local stream not cancelled')
                parent.shutdown(socket.SHUT_RDWR); parent.close()
            else:
                local_writer.write_eof(); await local_writer.drain()
                await receive(Kind.FIN)
                await send(Kind.FIN, process=process.process, stream=stream.stream)
                if await asyncio.wait_for(local_reader.read(), 5) != b'': raise RuntimeError('missing EOF')
                stopped = await receive(Kind.PROCESS_STOP)
                await send(Kind.PROCESS_RETIRED, process=stopped.process)
                parent.shutdown(socket.SHUT_RDWR); parent.close()
                await receive(Kind.REVOKE); await send(Kind.REVOKED)
            code = await asyncio.wait_for(proc.wait(), 10)
            err = (await proc.stderr.read()).decode(errors='replace')
            if code or path.exists(): raise RuntimeError(f'broker cleanup exit={code} stderr={err}')
            print('PASS fake executor: mode=' + ('drain' if draining else 'eof') + ', 101, CGLV receipts, ordered bytes, retirement, revoke, cleanup')
        finally:
            if local_writer:
                local_writer.close()
                with suppress(OSError): await local_writer.wait_closed()
            phone_writer.close()
            with suppress(OSError): await phone_writer.wait_closed()
            parent.close()
            if proc.returncode is None:
                proc.terminate()
                try: await asyncio.wait_for(proc.wait(), 3)
                except asyncio.TimeoutError: proc.kill(); await proc.wait()


if __name__ == '__main__': asyncio.run(main())
