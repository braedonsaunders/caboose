#!/usr/bin/env python3
"""The Linux executor: stands in for the phone's GPU executor (docs/gpu-live.md).

It connects to a computer's GPU broker as the phone does through the host relay (the
WebSocket upgrade with the relay's headers and the phone's capability names), negotiates
the v4 session, and runs each guest process's streams through the phone's native runtime
(libcaboose_gpu_executor.so, the pinned gfxstream fork) on the computer's Vulkan driver.
Presentation is offscreen: each bound window gets a headless surface, its swapchains
present into offscreen images, and presented frames are counted in the log.

    python3 executor.py --connect HOST:PORT --token-file FILE --library libcaboose_gpu_executor.so

The session follows LiveGPUNativeBinding and LiveGPUSession (CabooseKit); README.md lists
what it leaves out.
"""
import argparse
import base64
import errno
import faulthandler
import hashlib
import os
from pathlib import Path
import queue
import signal
import socket
import struct
import sys
import threading
import time
import uuid
import zlib

sys.path.insert(0, str(Path(__file__).resolve().parents[5] / 'guest' / 'gpu' / 'broker'))
from live_protocol import HEADER, Decoder, Envelope, Kind, encode  # noqa: E402
import live_compression  # noqa: E402
import native  # noqa: E402
import surfaces  # noqa: E402
from surfaces import FrameLog, NativeError, ProtocolViolation, SerialQueue, SurfaceController, log  # noqa: E402

PROTOCOL = 'caboose.gpu.live.v1'
# The phone's capabilities (LiveGPUConnection.features).
FEATURES = ('guest-handles,guest-handle-arrays,completion-feed,ordered-present,guest-images,guest-query-pools,'
            'shader-cache,executor-resume,zstd-stream,upload-cache,guest-buffer-views,batched-descriptor-sets-inline')
HELLO = (b'CBGLREF1' + struct.pack('<II', 4, 0x70) +
         bytes.fromhex('20d3bb2e30337cabf0febb006ed102ab25ccf6d9ddbfaf624c7e68f9040969c0'))
MAX_MESSAGE = 256 * 1024
MAX_PACKET, MAX_REPLY = 16 * 1024 * 1024, 1024 * 1024
REPLY_PIECE = 16 * 1024
SURFACE_KINDS = frozenset((16, 18, 20, 23, 25, 27, 29, 31, 32, 34, 39))
_GUID = b'258EAFA5-E914-47DA-95CA-C5AB0DC85B11'


class Closed(Exception):
    pass


class WebSocket:
    """The client side of the broker's WebSocket: binary messages, masked frames."""

    def __init__(self, sock):
        self.sock = sock
        self.write_lock = threading.Lock()
        self.buffer = bytearray()

    @classmethod
    def connect(cls, address, token, computer, executor, features):
        host, port = address.rsplit(':', 1)
        sock = socket.create_connection((host, int(port)), timeout=10)
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        key = base64.b64encode(os.urandom(16))
        request = (b'GET /gpu HTTP/1.1\r\nHost: ' + host.encode() + b'\r\nUpgrade: websocket\r\n'
                   b'Connection: Upgrade\r\nAuthorization: Bearer ' + token + b'\r\n'
                   b'X-Caboose-GPU-Computer: ' + computer.encode() + b'\r\n'
                   b'X-Caboose-GPU-Executor: ' + str(executor).encode() + b'\r\n'
                   b'X-Caboose-GPU-Features: ' + features.encode() + b'\r\n'
                   b'Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: ' + key + b'\r\n'
                   b'Sec-WebSocket-Protocol: ' + PROTOCOL.encode() + b'\r\n\r\n')
        sock.sendall(request)
        self = cls(sock)
        while b'\r\n\r\n' not in self.buffer:
            data = sock.recv(4096)
            if not data or len(self.buffer) > 16384:
                raise Closed('upgrade refused')
            self.buffer.extend(data)
        head, _, rest = bytes(self.buffer).partition(b'\r\n\r\n')
        self.buffer = bytearray(rest)
        lines = head.split(b'\r\n')
        headers = {k.strip().lower(): v.strip() for k, _, v in (line.partition(b':') for line in lines[1:])}
        accept = base64.b64encode(hashlib.sha1(key + _GUID).digest())
        if (not lines[0].startswith(b'HTTP/1.1 101 ') or headers.get(b'sec-websocket-accept') != accept or
                headers.get(b'sec-websocket-protocol') != PROTOCOL.encode() or b'sec-websocket-extensions' in headers):
            raise Closed('invalid upgrade response: ' + lines[0].decode(errors='replace'))
        sock.settimeout(None)
        return self

    def _read(self, count):
        while len(self.buffer) < count:
            data = self.sock.recv(1 << 20)
            if not data:
                raise Closed('connection ended')
            self.buffer.extend(data)
        value = bytes(self.buffer[:count])
        del self.buffer[:count]
        return value

    def receive(self):
        """The next binary message; None once the broker closed the connection normally."""
        message = bytearray()
        while True:
            first, second = self._read(2)
            if second & 0x80 or first & 0x70:
                raise Closed('masked or reserved server frame')
            length = second & 0x7f
            if length == 126:
                length = struct.unpack('!H', self._read(2))[0]
            elif length == 127:
                length = struct.unpack('!Q', self._read(8))[0]
            if length > MAX_MESSAGE:
                raise Closed('message limit')
            payload = self._read(length)
            opcode, fin = first & 0x0f, first & 0x80
            if opcode == 9:
                self._send(10, payload)
            elif opcode == 10:
                continue
            elif opcode == 8:
                code = struct.unpack('!H', payload[:2])[0] if len(payload) >= 2 else 1005
                try:
                    self._send(8, payload[:2])
                except OSError:
                    pass
                if code != 1000:
                    raise Closed(f'broker closed with {code}')
                return None
            elif opcode in (0, 2):
                message.extend(payload)
                if len(message) > MAX_MESSAGE:
                    raise Closed('message limit')
                if fin:
                    return bytes(message)
            else:
                raise Closed('unsupported frame')

    def _send(self, opcode, payload):
        n = len(payload)
        if n < 126:
            head = bytes((0x80 | opcode, 0x80 | n))
        elif n < 65536:
            head = bytes((0x80 | opcode, 0x80 | 126)) + struct.pack('!H', n)
        else:
            head = bytes((0x80 | opcode, 0x80 | 127)) + struct.pack('!Q', n)
        mask = os.urandom(4)
        repeated = (mask * (n // 4 + 1))[:n]
        masked = (int.from_bytes(payload, 'little') ^ int.from_bytes(repeated, 'little')).to_bytes(n, 'little')
        with self.write_lock:
            self.sock.sendall(head + mask + masked)

    def send(self, payload):
        self._send(2, payload)

    def close(self):
        try:
            self.sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        self.sock.close()


class Stream:
    """One broker stream: a socketpair whose native end the decoder runs on."""

    def __init__(self):
        self.bridge, self.native = socket.socketpair(socket.AF_UNIX, socket.SOCK_STREAM)
        for end in (self.bridge, self.native):
            end.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 16 * 1024)
            end.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 16 * 1024)
        self.inbound_finished = False
        self.native_ended = False
        self.threads = []

    def cancel(self):
        for end in (self.bridge, self.native):
            for how in (socket.SHUT_RD, socket.SHUT_WR):
                try:
                    end.shutdown(how)
                except OSError:
                    pass

    def join_and_close(self):
        for thread in self.threads:
            thread.join()
        self.bridge.close()
        self.native.close()


class Process:
    def __init__(self, token):
        self.token = token
        self.lock = threading.Lock()
        self.streams = {}
        self.stopped = False
        self.cleanup_error = None

    def stop(self, runtime):
        with self.lock:
            if self.stopped:
                return
            self.stopped = True
            for stream in self.streams.values():
                stream.cancel()
            code = runtime.runtime_stop(self.token)
            if code:
                self.cleanup_error = NativeError('stop', code)


class Executor:
    def __init__(self, runtime, socket_, options):
        self.rt, self.ws, self.options = runtime, socket_, options
        self.surfaces = SurfaceController(runtime, self._surface_send, self.fail, options.display,
                                          FrameLog(options.log_every), checksums=not options.no_checksums,
                                          fail_binds=options.fail_binds)
        self.decoder = None
        self.identity = None
        self.negotiated = False
        self.output_sequence = 1
        self.output_lock = threading.Lock()
        self.lock = threading.Lock()
        self.processes = {}
        self.opened_processes, self.opened_streams = set(), set()
        self.retiring = set()
        self.retirements = SerialQueue('caboose-retire', self.fail)
        self.compression = None
        self.zstd = None
        self.resumable = False
        self.first = True
        self.highest_acknowledged = 0
        self.unacknowledged_bytes = 0
        self.ack_timer = None
        self.peer_revoked = False
        self.receipt_sent = False
        self.drain_requested = self.drain_sent = False
        self.failure = None
        self.cancelled = False
        self.inbox = queue.Queue(maxsize=2048)

    # Output ---------------------------------------------------------------------------
    def send(self, kind, process=0, stream=0, payload=b''):
        with self.output_lock:
            if self.cancelled:
                raise Closed('executor cancelled')
            executor, generation = self.identity
            sequence = 0 if kind == Kind.ACK else self.output_sequence
            wire = encode(Envelope(Kind(kind), executor, generation, process, stream, sequence, payload))
            # Counted as sent before the bytes leave: the broker may acknowledge them at once.
            if kind != Kind.ACK:
                self.output_sequence += 1
            self.ws.send(wire)

    def _surface_send(self, kind, process, payload):
        self.send(kind, process=process, payload=payload)

    def fail(self, error):
        with self.lock:
            if self.failure:
                return
            self.failure = error
        log(f'executor failed: {error!r}')
        self.revoke()
        self.ws.close()

    # Input ----------------------------------------------------------------------------
    def read_loop(self):
        try:
            while True:
                message = self.ws.receive()
                self.inbox.put(message)
                if message is None:
                    return
        except Exception as error:
            self.inbox.put(error)

    def run(self):
        reader = threading.Thread(target=self.read_loop, name='caboose-network', daemon=True)
        reader.start()
        normal = False
        try:
            while True:
                item = self.inbox.get()
                if item is None:
                    normal = True
                    break
                if isinstance(item, Exception):
                    raise item
                if item == 'drain':
                    self.drain_requested = True
                    self._send_drain_if_ready()
                    continue
                self.consume(item)
        except Exception as error:
            if not self.failure:
                self.fail(error)
        started = time.monotonic()
        self.finish()
        log(f'cleanup took {time.monotonic() - started:.2f} s rss={resident_bytes() // (1 << 20)} MiB')
        if normal and self.receipt_sent and not self.failure:
            log('session ended: normal close after REVOKED')
            return 0
        log(f'session ended: {"normal close without REVOKED" if normal else repr(self.failure)}')
        return 1

    def consume(self, data):
        # Resume acknowledgements stand outside the sequence and the envelope decoder.
        if self._acknowledgement(data):
            return
        self.first = False
        if self.compression is not None and data[:4] == b'CGLZ':
            if self.decoder.buffered_bytes:
                raise ProtocolViolation('fragmented compressed transport')
            data = self._inflate(data)
        elif self.compression is not None:
            if self.decoder.buffered_bytes or len(data) < HEADER.size or \
                    struct.unpack_from('<I', data, 8)[0] != len(data) - HEADER.size:
                raise ProtocolViolation('compressed transport requires whole envelopes')
            if self.compression == 2 and struct.unpack_from('<H', data, 6)[0] == Kind.DATA:
                raise ProtocolViolation('raw DATA on the zstd stream')
        if self.decoder is None:
            self.decoder = Decoder()
        self.decoder.feed(data, self.handle)
        if self.resumable:
            self.unacknowledged_bytes += len(data)
            if self.unacknowledged_bytes >= 64 * 1024:
                self._acknowledge()
            elif not self.ack_timer:
                self.ack_timer = threading.Timer(0.05, lambda: self.inbox.put(b'ack'))
                self.ack_timer.daemon = True
                self.ack_timer.start()

    def _acknowledgement(self, data):
        if data == b'ack':  # this executor's own acknowledgement timer
            self.ack_timer = None
            if self.unacknowledged_bytes:
                self._acknowledge()
            return True
        if len(data) != HEADER.size + 8 or data[:4] != b'CGLV':
            return False
        kind = struct.unpack_from('<H', data, 6)[0]
        if kind == Kind.RESUME:
            raise ProtocolViolation('RESUME without a splice')
        if kind != Kind.ACK:
            return False
        if struct.unpack_from('<Q', data, 56)[0] != 0:
            raise ProtocolViolation('sequenced ACK')
        value = struct.unpack_from('<Q', data, HEADER.size)[0]
        if self.first:
            if value:
                raise ProtocolViolation('first ACK must be zero')
            self.resumable = True
            log('session is resumable: acknowledging the broker')
        elif not self.resumable:
            raise ProtocolViolation('ACK in a session that is not resumable')
        elif value < self.highest_acknowledged or value >= self.output_sequence:
            raise ProtocolViolation('acknowledgement out of range')
        self.highest_acknowledged = value
        self.first = False
        return True

    def _acknowledge(self):
        self.unacknowledged_bytes = 0
        if self.identity:
            self.send(Kind.ACK, payload=struct.pack('<Q', self.decoder.received))

    def _inflate(self, record):
        magic, version, algorithm, decoded, compressed = struct.unpack_from('<4sHHII', record)
        if version != 1 or algorithm != self.compression or compressed != len(record) - 16 or not 65 <= decoded <= 65600:
            raise ProtocolViolation('invalid compressed DATA')
        if algorithm == 2:
            data = self.zstd.decompress(record)
        else:
            inflater = zlib.decompressobj(-15)
            data = inflater.decompress(record[16:], decoded + 1)
            if not inflater.eof or inflater.unconsumed_tail or inflater.unused_data or len(record) - 16 >= decoded:
                raise ProtocolViolation('invalid DEFLATE record')
        if len(data) != decoded or data[:4] != b'CGLV' or struct.unpack_from('<H', data, 6)[0] != Kind.DATA:
            raise ProtocolViolation('compressed record is not one DATA envelope')
        return data

    # Envelopes ------------------------------------------------------------------------
    def handle(self, frame):
        if self.peer_revoked:
            raise Closed('envelope after REVOKE')
        if not self.negotiated:
            if frame.kind != Kind.SESSION or frame.payload != HELLO:
                raise ProtocolViolation('unsupported SESSION hello')
            code = self.rt.executor_start(self.options.loader.encode() if self.options.loader else None)
            if code:
                raise NativeError('start', code)
            if self.options.cache_root:
                self.rt.runtime_set_cache_root(str(Path(self.options.cache_root).resolve()).encode())
            if self.options.gpu_memory_limit:
                self.rt.runtime_set_memory_limit(self.options.gpu_memory_limit)
            self.identity = (frame.executor, frame.generation)
            self.negotiated = True
            self.send(Kind.SESSION_READY, payload=HELLO)
            log(f'session ready executor={uuid.UUID(bytes=frame.executor)} generation={frame.generation}')
            self._send_drain_if_ready()
            return
        kind = frame.kind
        if kind == Kind.TRANSPORT_CONFIG:
            if self.compression is not None or self.opened_processes or self.drain_requested:
                raise ProtocolViolation('unexpected compression negotiation')
            payload = frame.payload
            if payload == struct.pack('<II', 1, 65600):
                self.compression, answer = 1, payload
            else:
                algorithm, decoded, offered, reserved = struct.unpack('<IIII', payload)
                taken = min(offered, self.options.zstd_window_log)
                if algorithm != 2 or taken < 20:
                    raise ProtocolViolation('unexpected compression negotiation')
                self.zstd = live_compression.StreamDecompressor(taken)
                self.compression, answer = 2, struct.pack('<IIII', 2, decoded, taken, 0)
                log(f'compression algorithm=2 window_log={taken}')
            self.send(Kind.TRANSPORT_READY, payload=answer)
        elif kind == Kind.PROCESS_OPEN:
            with self.lock:
                full = len(self.processes) >= 16
            if frame.process in self.opened_processes or full:
                return self._dropped('process open', frame)
            token = native.ctypes.c_uint64()
            code = self.rt.runtime_open(native.ctypes.byref(token))
            if code or not token.value:
                raise NativeError('open', code or errno.EIO)
            process = Process(token.value)
            with self.lock:
                self.processes[frame.process] = process
                cancelled = self.cancelled
            if cancelled:
                process.stop(self.rt)
                raise Closed('executor cancelled')
            self.opened_processes.add(frame.process)
            self.send(Kind.PROCESS_READY, process=frame.process)
            log(f'process open id={frame.process} token={token.value}')
        elif kind == Kind.STREAM_OPEN:
            self._open_stream(frame)
        elif kind in (Kind.DATA, Kind.FIN):
            with self.lock:
                process = self.processes.get(frame.process)
            if not process:
                return self._dropped('stream data', frame)
            with process.lock:
                stream = process.streams.get(frame.stream)
                if not stream or stream.inbound_finished:
                    stream = None
                else:
                    if kind == Kind.FIN:
                        stream.inbound_finished = True
                    ended = stream.native_ended
            if not stream:
                return self._dropped('stream data', frame)
            if kind == Kind.DATA:
                if not ended:
                    stream.bridge.sendall(frame.payload)
            else:
                stream.bridge.shutdown(socket.SHUT_WR)
        elif kind in SURFACE_KINDS:
            with self.lock:
                process = self.processes.get(frame.process)
            if not process:
                self._dropped('surface record', frame)
                return self.surfaces.answer_for_unknown_process(kind, frame.payload, frame.process)
            self.surfaces.consume(kind, frame.payload, frame.process, process.token)
        elif kind == Kind.PROCESS_STOP:
            with self.lock:
                process = self.processes.get(frame.process)
            if not process:
                self._dropped('process stop', frame)
                return self.send(Kind.PROCESS_RETIRED, process=frame.process)
            with self.lock:
                if frame.process in self.retiring:
                    return
                self.retiring.add(frame.process)
            process.stop(self.rt)
            ident = frame.process

            def retire():
                self._retire(ident, process)
                self.send(Kind.PROCESS_RETIRED, process=ident)
            self.retirements.submit(retire)
        elif kind == Kind.REVOKE:
            self.peer_revoked = True
            self.retirements.sync(lambda: None)
            with self.lock:
                snapshot = dict(self.processes)
            for process in snapshot.values():
                process.stop(self.rt)
            for ident in sorted(snapshot):
                self._retire(ident, snapshot[ident])
                self.send(Kind.PROCESS_RETIRED, process=ident)
            self.send(Kind.REVOKED)
            self.receipt_sent = True
            log('revoked: every process retired')
        else:
            raise ProtocolViolation(f'unexpected peer message {kind!r}')

    def _send_drain_if_ready(self):
        if self.negotiated and self.drain_requested and not self.drain_sent and not self.peer_revoked:
            self.send(Kind.EXECUTOR_DRAIN)
            self.drain_sent = True
            log('drain requested')

    def _dropped(self, what, frame):
        log(f'dropped {what} kind={int(frame.kind)} process={frame.process} stream={frame.stream} '
            f'sequence={frame.sequence}')

    def _open_stream(self, frame):
        with self.lock:
            process = self.processes.get(frame.process)
            snapshot = list(self.processes.values())
        if not process:
            return self._dropped('stream open', frame)
        # Reclaim streams whose both directions ended and whose workers returned.
        count = 0
        for p in snapshot:
            with p.lock:
                for ident, stream in list(p.streams.items()):
                    if stream.inbound_finished and not any(t.is_alive() for t in stream.threads):
                        stream.join_and_close()
                        del p.streams[ident]
                count += len(p.streams)
        if frame.stream in self.opened_streams:
            return self._dropped('stream open', frame)
        if count >= 64:
            self._dropped('stream open over capacity', frame)
            self.opened_streams.add(frame.stream)
            return self.send(Kind.FIN, process=frame.process, stream=frame.stream)
        stream = Stream()
        with process.lock:
            process.streams[frame.stream] = stream
            if process.stopped:
                stream.cancel()
        self.opened_streams.add(frame.stream)
        log(f'stream open process={frame.process} stream={frame.stream}')
        gate = threading.Barrier(3)
        ident, stream_id = frame.process, frame.stream

        def run_native():
            gate.wait()
            result = self.rt.runtime_run(process.token, stream.native.fileno(), MAX_PACKET, MAX_REPLY)
            try:
                stream.native.shutdown(socket.SHUT_WR)
            except OSError:
                pass
            with process.lock:
                expected = (result == errno.ECANCELED and process.stopped) or (
                    result == errno.EPROTO and (process.stopped or stream.inbound_finished))
                if result and not expected:
                    stream.native_ended = True
            if result and not expected:
                log(f'stream ended by the decoder process={ident} stream={stream_id} errno={result}')

        def read_replies():
            gate.wait()
            while True:
                try:
                    data = stream.bridge.recv(REPLY_PIECE)
                except OSError as error:
                    if process.stopped:
                        return
                    return self.fail(error)
                if process.stopped:
                    return
                try:
                    if not data:
                        return self.send(Kind.FIN, process=ident, stream=stream_id)
                    self.send(Kind.DATA, process=ident, stream=stream_id, payload=data)
                except Exception as error:
                    return self.fail(error)
        stream.threads = [threading.Thread(target=run_native, name='caboose-decoder', daemon=True),
                          threading.Thread(target=read_replies, name='caboose-replies', daemon=True)]
        for thread in stream.threads:
            thread.start()
        try:
            self.send(Kind.STREAM_READY, process=frame.process, stream=frame.stream)
        finally:
            gate.wait()

    def _retire(self, ident, process):
        process.stop(self.rt)
        with process.lock:
            streams = list(process.streams.values())
        for stream in streams:
            stream.join_and_close()
        with process.lock:
            process.streams.clear()
        self.surfaces.retire_process(ident)
        started = time.monotonic()
        code = self.rt.runtime_finish(process.token)
        log(f'process finished id={ident} token={process.token} seconds={time.monotonic() - started:.2f}')
        with self.lock:
            self.processes.pop(ident, None)
            self.retiring.discard(ident)
        if code:
            raise NativeError('finish', code)
        if process.cleanup_error:
            raise process.cleanup_error
        log(f'process retired id={ident} token={process.token}')

    # Teardown -------------------------------------------------------------------------
    def revoke(self):
        with self.lock:
            self.cancelled = True
            snapshot = list(self.processes.values())
        for process in snapshot:
            process.stop(self.rt)

    def finish(self):
        self.retirements.sync(lambda: None)
        self.revoke()
        with self.lock:
            snapshot = dict(self.processes)
        for ident, process in snapshot.items():
            try:
                self._retire(ident, process)
            except Exception as error:
                log(f'cleanup failed for process {ident}: {error!r}')
        self.retirements.close()
        self.ws.close()


def resident_bytes():
    """The executor process's resident memory, which holds the decoder's objects and, on
    lavapipe, their memory."""
    try:
        for line in Path('/proc/self/status').read_text().splitlines():
            if line.startswith('VmRSS:'):
                return int(line.split()[1]) * 1024
    except OSError:
        pass
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    parser.add_argument('--connect', required=True, metavar='HOST:PORT', help="the broker's WebSocket endpoint")
    parser.add_argument('--token-file', type=Path, required=True, help="the computer's per-wake GPU token")
    parser.add_argument('--library', type=Path, required=True, help='libcaboose_gpu_executor.so')
    parser.add_argument('--loader', default='libvulkan.so.1', help='the Vulkan loader the decoder runs on')
    parser.add_argument('--features', default=FEATURES, help="capability names (default: the phone's)")
    parser.add_argument('--computer', default='linux-executor', help='the X-Caboose-GPU-Computer identity')
    parser.add_argument('--cache-root', help='directory for the shader and upload caches')
    parser.add_argument('--gpu-memory-limit', type=int, default=0, metavar='BYTES',
                        help='limit on the device memory guests hold (docs/gpu-live.md, "Memory budget")')
    parser.add_argument('--display', default='1920x1080', help='extent of a window bound without one')
    parser.add_argument('--zstd-window-log', type=int, default=27)
    parser.add_argument('--log-every', type=int, default=60, help='log every Nth presented frame of a swapchain')
    parser.add_argument('--extra-formats', default='', metavar='FORMAT:SPACE,...',
                        help='surface formats to report beyond the implementation\'s (VkFormat:VkColorSpaceKHR numbers)')
    parser.add_argument('--no-checksums', action='store_true', help='do not capture presented pictures')
    parser.add_argument('--pictures', type=Path, metavar='DIR',
                        help="write each window's newest captured picture to DIR/window-ID.ppm, with its content "
                             'measures in the log (the repeat fraction and colours: surfaces.content), at most ten a second')
    parser.add_argument('--fail-binds', type=int, default=0, metavar='N',
                        help="answer each session's first N surface binds with EAGAIN, as a phone whose layer is not ready does")
    parser.add_argument('--sessions', type=int, default=1, metavar='N',
                        help='connect again after a session ends, as the phone does, for N sessions in all')
    options = parser.parse_args()
    if options.pictures:
        options.pictures.mkdir(parents=True, exist_ok=True)
        surfaces.PICTURES['directory'] = str(options.pictures)
    surfaces.EXTRA_FORMATS[:] = [tuple(int(n) for n in pair.split(':')) for pair in options.extra_formats.split(',') if pair]
    width, _, height = options.display.partition('x')
    options.display = (int(width), int(height))
    # The shader and upload caches need their stores: without --cache-root the executor
    # cannot resolve what a guest names by hash, so it does not offer them.
    if not options.cache_root:
        kept = [name for name in options.features.split(',') if name not in ('shader-cache', 'upload-cache')]
        if len(kept) != len(options.features.split(',')):
            log('no --cache-root: shader-cache and upload-cache not offered')
        options.features = ','.join(kept)
    runtime = native.Runtime(str(options.library))
    current = []
    draining = []

    def drain(*_):
        draining.append(True)
        if current:
            current[-1].inbox.put('drain')
    signal.signal(signal.SIGTERM, drain)
    # SIGUSR1 prints every thread's stack, for a session that stops making progress.
    faulthandler.register(signal.SIGUSR1, all_threads=True)
    faulthandler.enable(all_threads=True)
    signal.signal(signal.SIGINT, drain)
    code = 1
    for session in range(options.sessions):
        # A later session waits for the broker to come back, as the phone reconnects.
        deadline = time.monotonic() + (0 if session == 0 else 60)
        while True:
            try:
                token = options.token_file.read_bytes().strip()
                executor_id = uuid.uuid4()
                socket_ = WebSocket.connect(options.connect, token, options.computer, executor_id, options.features)
                break
            except OSError:
                if time.monotonic() >= deadline:
                    raise
                time.sleep(0.5)
        log(f'connected to {options.connect} executor={executor_id} features={options.features} '
            f'session={session + 1} rss={resident_bytes() // (1 << 20)} MiB')
        executor = Executor(runtime, socket_, options)
        current.append(executor)
        if draining:
            executor.inbox.put('drain')
        code = executor.run()
        if draining:
            break
    time.sleep(0.1)
    os._exit(code)


if __name__ == '__main__':
    main()
