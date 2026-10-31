"""Bounded client WebSocket frame decoding for the private live GPU transport.

This parser handles framing only. The caller authenticates the HTTP upgrade,
enforces the connection's queue limits, and validates CGLV bytes separately.
"""
import struct

MAX_MESSAGE = 256 * 1024


class WebSocketError(ValueError):
    pass


class Decoder:
    def __init__(self):
        self._raw = bytearray()
        self._fragment = bytearray()
        self._fragmenting = False
        self._ended = False

    def feed(self, data, deliver):
        if self._ended:
            raise WebSocketError('connection closed')
        try:
            view = memoryview(data)
            while view:
                # A single frame cannot exceed this bound, including header.
                room = MAX_MESSAGE + 14 - len(self._raw)
                if not room:
                    raise WebSocketError('frame limit')
                take = min(room, len(view))
                self._raw.extend(view[:take])
                view = view[take:]
                self._drain(deliver)
                if self._ended and view:
                    raise WebSocketError('bytes after close')
        except Exception:
            self._ended = True
            self._raw.clear()
            self._fragment.clear()
            raise

    def _drain(self, deliver):
        while len(self._raw) >= 2:
            first, second = self._raw[0], self._raw[1]
            fin, opcode = bool(first & 0x80), first & 0x0f
            if first & 0x70 or not second & 0x80:
                raise WebSocketError('reserved bits or unmasked frame')
            length, start = second & 0x7f, 2
            if length == 126:
                if len(self._raw) < 4: return
                length = struct.unpack_from('!H', self._raw, 2)[0]; start = 4
                if length < 126: raise WebSocketError('nonminimal frame length')
            elif length == 127:
                if len(self._raw) < 10: return
                length = struct.unpack_from('!Q', self._raw, 2)[0]; start = 10
                if length < 65536 or length & (1 << 63):
                    raise WebSocketError('invalid frame length')
            if opcode not in (0, 2, 8, 9, 10):
                raise WebSocketError('unsupported frame type')
            if opcode >= 8 and (not fin or length > 125):
                raise WebSocketError('invalid control frame')
            if length > MAX_MESSAGE:
                raise WebSocketError('frame limit')
            if len(self._raw) < start + 4 + length: return
            mask = self._raw[start:start + 4]; start += 4
            payload = bytes(v ^ mask[i & 3] for i, v in enumerate(self._raw[start:start + length]))
            del self._raw[:start + length]
            if opcode == 2:
                if self._fragmenting: raise WebSocketError('nested fragmented message')
                if fin: deliver('binary', payload)
                else:
                    self._fragmenting = True
                    self._fragment.extend(payload)
            elif opcode == 0:
                if not self._fragmenting: raise WebSocketError('unexpected continuation')
                if len(self._fragment) + len(payload) > MAX_MESSAGE:
                    raise WebSocketError('message limit')
                self._fragment.extend(payload)
                if fin:
                    self._fragmenting = False
                    complete = bytes(self._fragment); self._fragment.clear()
                    deliver('binary', complete)
            elif opcode == 8:
                if len(payload) == 1:
                    raise WebSocketError('invalid close payload')
                if len(payload) >= 2:
                    code = int.from_bytes(payload[:2], 'big')
                    if code < 1000 or code in (1004, 1005, 1006, 1015) or 1016 <= code < 3000 or code >= 5000:
                        raise WebSocketError('invalid close code')
                    try: payload[2:].decode('utf-8')
                    except UnicodeDecodeError as error: raise WebSocketError('invalid close text') from error
                if self._fragmenting:
                    raise WebSocketError('truncated fragmented message')
                self._ended = True
                deliver('close', payload)
                if self._raw: raise WebSocketError('bytes after close')
                return
            elif opcode == 9: deliver('ping', payload)
            else: deliver('pong', payload)

    def eof(self):
        if self._raw or self._fragmenting:
            self._ended = True
            raise WebSocketError('truncated WebSocket frame')
        self._ended = True


def server_frame(opcode, payload):
    if opcode not in (2, 8, 9, 10) or len(payload) > (125 if opcode >= 8 else MAX_MESSAGE):
        raise WebSocketError('invalid server frame')
    n = len(payload)
    if n < 126: header = bytes((0x80 | opcode, n))
    elif n < 65536: header = bytes((0x80 | opcode, 126)) + struct.pack('!H', n)
    else: header = bytes((0x80 | opcode, 127)) + struct.pack('!Q', n)
    return header + payload
