"""CGLS v1 records for the private, per-surface Unix socket."""
import struct

from live_surface_protocol import validate_surface

HEADER = struct.Struct('<4sHHII')
MAX_RECORD = 256 * 1024
_IDENTITY = b'\x01' * 32 + struct.pack('<Q', 1)


def decode_request(data):
    """Validate one complete client seqpacket; return its kind and body."""
    if len(data) < HEADER.size or len(data) > MAX_RECORD:
        raise ValueError('invalid CGLS record size')
    magic, version, kind, length, reserved = HEADER.unpack_from(data)
    if magic != b'CGLS' or version != 1 or length != len(data) or reserved:
        raise ValueError('invalid CGLS header')
    body = data[HEADER.size:]
    if kind == 16:
        if len(body) != 24:
            raise ValueError('invalid bind size')
        instance, obj, width, height, tail = struct.unpack('<QIIII', body)
        if not instance or not obj or tail or bool(width) != bool(height):
            raise ValueError('invalid bind fields')
    elif kind == 18:
        if len(body) != 16 or not all(struct.unpack('<QQ', body)):
            raise ValueError('invalid query')
    elif kind in (20, 25, 27, 29, 31, 32, 34):
        validate_surface(kind, _IDENTITY + body)
    elif kind == 23:
        if body:
            raise ValueError('invalid retirement')
    else:
        raise ValueError('unexpected CGLS request')
    return kind, body


def encode_reply(kind, body):
    """Encode an actual native reply or a local terminal transport error."""
    if kind == 17:
        if len(body) != 64 or not struct.unpack_from('<Q', body)[0]:
            raise ValueError('invalid bind reply')
        validate_surface(kind, body[8:])
    elif kind in (19, 21, 22, 24, 26, 28, 30, 33, 35, 36):
        validate_surface(kind, body)
    elif kind == 0x7fff:
        if len(body) != 16:
            raise ValueError('invalid local error')
        error, has_vk, vk, reserved = struct.unpack('<iIiI', body)
        if error <= 0 or has_vk or vk or reserved:
            raise ValueError('invalid local error')
    else:
        raise ValueError('unexpected CGLS reply')
    length = HEADER.size + len(body)
    if length > MAX_RECORD:
        raise ValueError('CGLS reply too large')
    return HEADER.pack(b'CGLS', 1, kind, length, 0) + body
