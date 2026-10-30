#!/usr/bin/env python3
"""Private fake-executor transport check; it does not issue Vulkan commands."""
import array
import asyncio
import json
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
from process_binding import pidfd_pid

HELLO = (b'CBGLREF1' + bytes((3, 0, 0, 0, 48, 0, 0, 0)) + bytes.fromhex(
    '20d3bb2e30337cabf0febb006ed102ab25ccf6d9ddbfaf624c7e68f9040969c0'))
EXECUTOR = bytes.fromhex('00112233445566778899aabbccddeeff')


async def main():
    draining = '--drain' in sys.argv[1:]
    indexed = '--indexed' in sys.argv[1:]
    withhold = '--withhold-revoked' in sys.argv[1:]
    invalid_after = '--invalid-after-revoked' in sys.argv[1:]
    if (withhold or invalid_after) and not draining: raise ValueError('failure modes require --drain')
    if withhold and invalid_after: raise ValueError('select one failure mode')
    reject = [name for name in ('v2', 'v3', 'bits') if '--reject-' + name in sys.argv[1:]]
    if len(reject) > 1 or (reject and not indexed): raise ValueError('one rejection mode requires --indexed')
    hello = (HELLO[:8] + struct.pack('<II', 4, 0x70) + HELLO[16:]) if indexed else HELLO
    with tempfile.TemporaryDirectory(prefix='gpu-loopback-', dir=os.environ['GPU_TRIAL_DIR']) as d:
        root = Path(d); token = root / 'token'; token.write_bytes(b'test-token')
        path = root / 'gpu.sock'
        parent, child = socket.socketpair(type=socket.SOCK_SEQPACKET)
        command = [sys.executable, str(Path(__file__).with_name('caboose-gpu-broker')),
                   '--control-fd=0', '--token-file', str(token), '--socket', str(path)]
        if indexed: command.extend(('--surface-socket', str(root / 'surface.sock'), '--private-indexed'))
        proc = await asyncio.create_subprocess_exec(
            *command,
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
        local_surface = None
        try:
            request = (b'GET /gpu HTTP/1.1\r\nHost: guest\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n'
                       b'Authorization: Bearer test-token\r\nX-Caboose-GPU-Computer: test\r\n'
                       b'X-Caboose-GPU-Executor: 00112233-4455-6677-8899-aabbccddeeff\r\n'
                       b'Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n'
                       b'Sec-WebSocket-Protocol: caboose.gpu.live.v1\r\n\r\n')
            async def assert_lease_latched():
                try: unexpected = parent.recv(80)
                except BlockingIOError: unexpected = None
                if unexpected is not None:
                    raise RuntimeError('unexpected compositor retirement receipt after failure')
                listener = socket.socket(); listener.bind(('127.0.0.1', 0)); listener.listen(1)
                retry = socket.socket(); retry.connect(listener.getsockname())
                accepted, _ = listener.accept(); listener.close()
                try:
                    parent.sendmsg([b'G'], [(socket.SOL_SOCKET, socket.SCM_RIGHTS, array.array('i', [accepted.fileno()]))])
                finally: accepted.close()
                retry.setblocking(False)
                retry_reader, retry_writer = await asyncio.open_connection(sock=retry)
                try:
                    retry_writer.write(request); await retry_writer.drain()
                    if await asyncio.wait_for(retry_reader.read(1), 5) != b'':
                        raise RuntimeError('failed executor lease was released')
                finally:
                    retry_writer.close()
                    with suppress(OSError): await retry_writer.wait_closed()
            phone_writer.write(request); await phone_writer.drain()
            response = await asyncio.wait_for(phone_reader.readuntil(b'\r\n\r\n'), 5)
            if not response.startswith(b'HTTP/1.1 101 '): raise RuntimeError('upgrade failed')
            first = await receive(Kind.SESSION)
            if first.payload != hello: raise RuntimeError('session hello mismatch')
            if reject:
                invalid = {'v2': HELLO[:8] + struct.pack('<II', 2, 0x10) + HELLO[16:],
                           'v3': HELLO,
                           'bits': hello[:12] + struct.pack('<I', 0xf0) + hello[16:]}[reject[0]]
                await send(Kind.SESSION_READY, payload=invalid)
                if await asyncio.wait_for(phone_reader.read(), 5) != b'': raise RuntimeError('mismatched hello accepted')
                if path.exists() or (root / 'surface.sock').exists(): raise RuntimeError('socket published on mismatched hello')
                parent.shutdown(socket.SHUT_RDWR); parent.close()
                if await asyncio.wait_for(proc.wait(), 10): raise RuntimeError('broker failed to exit')
                print(f'PASS fake executor: v4 rejects {reject[0]} before local socket publication')
                return
            await send(Kind.SESSION_READY, payload=hello)
            ready_record = await asyncio.wait_for(asyncio.get_running_loop().sock_recv(parent, 80), 5)
            if control_protocol.decode(ready_record, 0) != control_protocol.ExecutorLifecycle(4, EXECUTOR, 1):
                raise RuntimeError('missing actual session-ready control')
            for _ in range(100):
                if path.exists(): break
                await asyncio.sleep(.02)
            if not path.exists(): raise RuntimeError('local socket not ready')
            local_reader, local_writer = await asyncio.open_unix_connection(str(path))
            local_writer.write(hello); await local_writer.drain()
            process = await receive(Kind.PROCESS_OPEN)
            await send(Kind.PROCESS_READY, process=process.process)
            stream = await receive(Kind.STREAM_OPEN)
            await send(Kind.STREAM_READY, process=process.process, stream=stream.stream)
            if await asyncio.wait_for(local_reader.readexactly(48), 5) != hello: raise RuntimeError('local hello mismatch')
            if indexed:
                loop = asyncio.get_running_loop()
                local_surface = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET)
                local_surface.setblocking(False)
                await loop.sock_connect(local_surface, str(root / 'surface.sock'))
                async def local_control(kind, body=b''):
                    packet = struct.pack('<4sHHII', b'CGLS', 1, kind, 16 + len(body), 0) + body
                    await loop.sock_sendall(local_surface, packet)
                async def local_reply(kind):
                    packet = await asyncio.wait_for(loop.sock_recv(local_surface, 4096), 5)
                    if len(packet) < 16 or struct.unpack_from('<H', packet, 6)[0] != kind:
                        raise RuntimeError('unexpected local surface reply')
                    return packet[16:]
                async def control_record():
                    while True:
                        try:
                            return parent.recvmsg(80, socket.CMSG_SPACE(array.array('i').itemsize))
                        except BlockingIOError:
                            ready = loop.create_future()
                            loop.add_reader(parent.fileno(), lambda: not ready.done() and ready.set_result(None))
                            try: await asyncio.wait_for(ready, 5)
                            finally: loop.remove_reader(parent.fileno())
                await local_control(16, struct.pack('<QIIII', 8, 17, 0, 0, 0))
                raw, ancillary, flags, _ = await control_record()
                if flags & (socket.MSG_TRUNC | socket.MSG_CTRUNC) or len(ancillary) != 1:
                    raise RuntimeError('invalid compositor bind ancillary data')
                fds = array.array('i'); fds.frombytes(ancillary[0][2][:fds.itemsize])
                try:
                    bind = control_protocol.decode(raw, len(fds))
                    if bind.process != process.process or bind.pid != os.getpid() or pidfd_pid(fds[0]) != os.getpid():
                        raise RuntimeError('surface bind lost kernel process identity')
                finally:
                    for fd in fds: os.close(fd)
                result = control_protocol.BindResult(bind.request, 0, b'e' * 16, b'g' * 16, 9, 1)
                await loop.sock_sendall(parent, control_protocol.encode_result(result))
                identity = result.epoch + result.grant + struct.pack('<Q', result.generation)
                frame = await receive(Kind.SURFACE_BIND)
                if frame.process != process.process or frame.payload[:40] != identity:
                    raise RuntimeError('surface bind identity mismatch')
                await send(Kind.SURFACE_BOUND, process.process, payload=identity + struct.pack('<iIiI', 0, 1, 0, 0))
                if (await local_reply(17))[8:48] != identity: raise RuntimeError('surface bind reply mismatch')
                vectors = json.loads((Path(__file__).parent.parent / 'broker' / 'live-swapchain-vectors.json').read_text())
                values = {item['name']: bytes.fromhex(item['payload']) for item in vectors}
                for request_kind, request_name, reply_kind, reply_name in (
                        (Kind.SWAPCHAIN_CREATE, 'create', Kind.SWAPCHAIN_CREATED, 'created'),
                        (Kind.SWAPCHAIN_MAP, 'map', Kind.SWAPCHAIN_MAPPED, 'mapped'),
                        (Kind.SWAPCHAIN_ACQUIRE, 'acquire', Kind.SWAPCHAIN_ACQUIRED, 'acquired')):
                    await local_control(request_kind, values[request_name][40:])
                    forwarded = await receive(request_kind)
                    if forwarded.payload != identity + values[request_name][40:]: raise RuntimeError('indexed request changed')
                    expected = identity + values[reply_name][40:]
                    await send(reply_kind, process.process, payload=expected)
                    if await local_reply(reply_kind) != expected: raise RuntimeError('indexed native reply changed')
                await local_control(Kind.SWAPCHAIN_PRESENT, values['indexed-present'][40:])
                present = await receive(Kind.SWAPCHAIN_PRESENT)
                serial = struct.unpack_from('<Q', present.payload, 48)[0]
                replies = [(Kind.PRESENT_RESULT, identity + struct.pack('<QiIiIII', serial, 0, 1, 0, 0, 1, 0)),
                           (Kind.SOURCE_RELEASED, identity + struct.pack('<Q', serial)),
                           (Kind.PRESENT_RETIRED, identity + struct.pack('<QQ', 5, serial))]
                for kind, expected in replies:
                    await send(kind, process.process, payload=expected)
                    if await local_reply(kind) != expected: raise RuntimeError('present completion changed')
                await local_control(Kind.SURFACE_RETIRE)
                raw, ancillary, flags, _ = await control_record()
                revoke = control_protocol.decode(raw, len(ancillary))
                if revoke != control_protocol.RevokeRequest(result.epoch, result.grant, result.generation):
                    raise RuntimeError('missing compositor revoke request')
                await loop.sock_sendall(parent, control_protocol.encode_revoke(control_protocol.RevokeGrant(
                    result.epoch, result.grant, result.generation)))
                retire = await receive(Kind.SURFACE_RETIRE)
                if retire.payload != identity: raise RuntimeError('surface retirement identity mismatch')
                await send(Kind.SURFACE_RETIRED, process.process, payload=identity + struct.pack('<iIiI', 0, 1, 0, 0))
                raw, ancillary, flags, _ = await control_record()
                if control_protocol.decode(raw, len(ancillary)) != control_protocol.GrantRetired(
                        result.epoch, result.grant, result.generation):
                    raise RuntimeError('missing actual retirement receipt')
                if (await local_reply(24))[:40] != identity: raise RuntimeError('surface retirement reply mismatch')
                local_surface.close(); local_surface = None
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
                await receive(Kind.REVOKE)
                try:
                    unexpected = await asyncio.wait_for(phone_reader.read(1), .2)
                except asyncio.TimeoutError:
                    pass
                else:
                    raise RuntimeError(f'connection closed or sent data before REVOKED: {unexpected!r}')
                if withhold:
                    if await asyncio.wait_for(phone_reader.read(), 6) != b'':
                        raise RuntimeError('normal close sent without native REVOKED')
                    await assert_lease_latched()
                    parent.shutdown(socket.SHUT_RDWR); parent.close()
                    if await asyncio.wait_for(proc.wait(), 10): raise RuntimeError('broker failed to exit')
                    print('PASS fake executor: missing REVOKED never sends normal close')
                    return
                if invalid_after:
                    revoked = encode(Envelope(Kind.REVOKED, EXECUTOR, 1, 0, 0, incoming_sequence, b''))
                    invalid = encode(Envelope(Kind.DATA, EXECUTOR, 1, 999, 999, incoming_sequence + 1, b'x'))
                    incoming_sequence += 2
                    phone_writer.write(client_frame(2, revoked) + client_frame(2, invalid))
                    await phone_writer.drain()
                    if await asyncio.wait_for(phone_reader.read(), 5) != b'':
                        raise RuntimeError('normal close sent after malformed executor control')
                    await assert_lease_latched()
                    parent.shutdown(socket.SHUT_RDWR); parent.close()
                    if await asyncio.wait_for(proc.wait(), 10): raise RuntimeError('broker failed to exit')
                    print('PASS fake executor: malformed control after REVOKED never sends normal close')
                    return
                await send(Kind.REVOKED)
                retired_record = await asyncio.wait_for(asyncio.get_running_loop().sock_recv(parent, 80), 5)
                if control_protocol.decode(retired_record, 0) != control_protocol.ExecutorLifecycle(6, EXECUTOR, 1):
                    raise RuntimeError('missing native-retired control')
                if await asyncio.wait_for(phone_reader.readexactly(4), 5) != b'\x88\x02\x03\xe8':
                    raise RuntimeError('missing normal WebSocket close after native retirement')
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
            if code or path.exists() or (indexed and (root / 'surface.sock').exists()):
                raise RuntimeError(f'broker cleanup exit={code} stderr={err}')
            print('PASS fake executor: version=' + ('v4' if indexed else 'v3') + ', mode=' + ('drain' if draining else 'eof') + ', 101, CGLV receipts, ordered bytes, retirement, revoke, cleanup')
        finally:
            if local_surface: local_surface.close()
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
