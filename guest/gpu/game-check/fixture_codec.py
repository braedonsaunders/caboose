"""Display fixture CBOR codec, adapted from check-output-resize.py; retain frame bytes."""
import struct

def encode(value):
    def head(major, n):
        if n < 24:
            return bytes([major * 32 + n])
        for tag, size in [(24, 1), (25, 2), (26, 4), (27, 8)]:
            if n < 1 << (size * 8):
                return bytes([major * 32 + tag]) + n.to_bytes(size, 'big')
        raise ValueError(n)
    if isinstance(value, bool):
        return b'\xf5' if value else b'\xf4'
    if isinstance(value, int):
        return head(0, value)
    if isinstance(value, float):
        return b'\xfb' + struct.pack('>d', value)
    if isinstance(value, str):
        raw = value.encode()
        return head(3, len(raw)) + raw
    if isinstance(value, list):
        return head(4, len(value)) + b''.join(map(encode, value))
    if isinstance(value, dict):
        fields = sorted((encode(k), encode(v)) for k, v in value.items())
        return head(5, len(fields)) + b''.join(k + v for k, v in fields)
    raise TypeError(type(value))

def decode(data, at=0):
    first = data[at]
    major, info = first >> 5, first & 31
    at += 1
    if major == 7 and info in (20, 21, 22):
        return {20: False, 21: True, 22: None}[info], at
    n = info
    if info >= 24:
        size = {24: 1, 25: 2, 26: 4, 27: 8}[info]
        n = int.from_bytes(data[at:at + size], 'big')
        at += size
    if major in (0, 1):
        return (n if major == 0 else -1 - n), at
    if major in (2, 3):
        value = data[at:at + n]
        return (value if major == 2 else value.decode()), at + n
    if major in (4, 5):
        result = [] if major == 4 else {}
        for _ in range(n):
            value, at = decode(data, at)
            if major == 4:
                result.append(value)
            else:
                result[value], at = decode(data, at)
        return result, at
    if major == 7 and info in (26, 27):
        return struct.unpack('>f' if info == 26 else '>d', n.to_bytes(4 if info == 26 else 8, 'big'))[0], at
    raise ValueError((major, info))
