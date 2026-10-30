"""Bounded live-GPU envelope framing, independent of Vulkan and display framing.

The codec validates identity, order and structural scope. It does not authenticate
an executor or make a ready/retired message evidence of a native operation.
"""

from dataclasses import dataclass
from enum import IntEnum
import struct
from live_surface_protocol import validate_surface

PROTOCOL = "caboose.gpu.live.v1"
MAX_MESSAGE = 256 * 1024
HEADER = struct.Struct("<4sHHII16sQQQQ")
MAX_PAYLOAD = MAX_MESSAGE - HEADER.size


class Kind(IntEnum):
    SESSION = 1
    SESSION_READY = 2
    PROCESS_OPEN = 3
    PROCESS_READY = 4
    STREAM_OPEN = 5
    STREAM_READY = 6
    DATA = 7
    FIN = 8
    PROCESS_STOP = 9
    PROCESS_RETIRED = 10
    REVOKE = 11
    REVOKED = 12
    EXECUTOR_DRAIN = 13
    SURFACE_BIND = 16
    SURFACE_BOUND = 17
    SURFACE_QUERY = 18
    SURFACE_CAPS = 19
    PRESENT = 20
    PRESENT_RESULT = 21
    SOURCE_RELEASED = 22
    SURFACE_RETIRE = 23
    SURFACE_RETIRED = 24


class ProtocolError(ValueError):
    pass


def _surface(kind, payload):
    try:
        validate_surface(kind, payload)
    except ValueError as error:
        raise ProtocolError(str(error)) from error


@dataclass(frozen=True)
class Envelope:
    kind: Kind
    executor: bytes
    generation: int
    process: int
    stream: int
    sequence: int
    payload: bytes = b""


def _validate(kind, executor, generation, process, stream, sequence, length):
    try:
        kind = Kind(kind)
    except ValueError as error:
        raise ProtocolError("unknown message kind") from error
    if len(executor) != 16 or executor == bytes(16):
        raise ProtocolError("invalid executor identity")
    if not 1 <= generation < 2**64 or not 1 <= sequence < 2**64:
        raise ProtocolError("invalid generation or sequence")
    if not 0 <= process < 2**64 or not 0 <= stream < 2**64:
        raise ProtocolError("invalid resource identity")
    if not 0 <= length <= MAX_PAYLOAD:
        raise ProtocolError("payload limit")
    if kind in (Kind.SESSION, Kind.SESSION_READY, Kind.REVOKE, Kind.REVOKED, Kind.EXECUTOR_DRAIN):
        if process or stream:
            raise ProtocolError("session message has resource identity")
    elif kind in (Kind.PROCESS_OPEN, Kind.PROCESS_READY, Kind.PROCESS_STOP, Kind.PROCESS_RETIRED) or kind >= Kind.SURFACE_BIND:
        if not process or stream:
            raise ProtocolError("invalid process scope")
    elif not process or not stream:
        raise ProtocolError("invalid stream scope")
    if kind >= Kind.SURFACE_BIND:
        if length < 40:
            raise ProtocolError("truncated surface control")
    elif kind in (Kind.SESSION, Kind.SESSION_READY):
        if length != 48:
            raise ProtocolError("invalid hello size")
    elif kind == Kind.DATA:
        if not length:
            raise ProtocolError("empty data")
    elif length:
        raise ProtocolError("unexpected control payload")
    return kind


def encode(message: Envelope) -> bytes:
    kind = _validate(message.kind, message.executor, message.generation,
                     message.process, message.stream, message.sequence, len(message.payload))
    if kind >= Kind.SURFACE_BIND:
        _surface(kind, message.payload)
    return HEADER.pack(b"CGLV", 1, kind, len(message.payload), 0, message.executor,
                       message.generation, message.process, message.stream,
                       message.sequence) + message.payload


class Decoder:
    """Single-consumer incremental parser with at most one bounded partial frame.

    deliver is synchronous: callers must apply bounded admission before retaining
    the frame. An exception from delivery poisons this connection too. No scanning
    for a new magic after errors, no cross-generation reuse, and no silent EOF.
    The authenticated endpoint supplies expected identity when it already knows it;
    otherwise the first SESSION establishes it on this transport only.
    """

    def __init__(self, executor=None, generation=None):
        if (executor is None) != (generation is None):
            raise ValueError("identity must be supplied together")
        self.executor = executor
        self.generation = generation
        self._sequence = 1
        self._buffer = bytearray()
        self._header = None
        self._ended = False

    @property
    def buffered_bytes(self):
        return len(self._buffer)

    def feed(self, data: bytes, deliver):
        if self._ended:
            raise ProtocolError("connection ended")
        try:
            if len(data) > MAX_MESSAGE:
                raise ProtocolError("WebSocket message limit")
            remaining = memoryview(data)
            while remaining:
                target = HEADER.size if self._header is None else self._header[3]
                take = min(target - len(self._buffer), len(remaining))
                self._buffer.extend(remaining[:take])
                remaining = remaining[take:]
                if len(self._buffer) != target:
                    continue
                if self._header is None:
                    values = HEADER.unpack(self._buffer)
                    magic, version, kind, length, reserved, executor, generation, process, stream, sequence = values
                    if magic != b"CGLV" or version != 1 or reserved:
                        raise ProtocolError("invalid header")
                    kind = _validate(kind, executor, generation, process, stream, sequence, length)
                    if sequence != self._sequence:
                        raise ProtocolError("sequence mismatch")
                    if self.executor is None:
                        if kind != Kind.SESSION:
                            raise ProtocolError("session must establish identity")
                        self.executor, self.generation = executor, generation
                    elif executor != self.executor or generation != self.generation:
                        raise ProtocolError("executor generation mismatch")
                    self._header = values
                    self._buffer.clear()
                    if length:
                        continue
                _, _, kind, _, _, executor, generation, process, stream, sequence = self._header
                frame = Envelope(Kind(kind), executor, generation, process, stream,
                                 sequence, bytes(self._buffer))
                if frame.kind >= Kind.SURFACE_BIND:
                    _surface(frame.kind, frame.payload)
                self._header = None
                self._buffer.clear()
                self._sequence += 1
                deliver(frame)
        except Exception:
            self._ended = True
            self._buffer.clear()
            self._header = None
            raise

    def finish(self):
        if self._ended:
            raise ProtocolError("connection ended")
        self._ended = True
        if self._header is not None or self._buffer:
            self._buffer.clear()
            self._header = None
            raise ProtocolError("truncated envelope")
