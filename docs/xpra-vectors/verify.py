#!/usr/bin/env python3
"""Check redacted frames and documented codec examples using Xpra itself."""
import json
import struct
import sys
from xpra.net.rencodeplus.rencodeplus import dumps, loads


def from_json(value):
    if isinstance(value, list):
        return tuple(from_json(x) for x in value)
    if isinstance(value, dict):
        if set(value) == {'bytes_hex'}:
            return bytes.fromhex(value['bytes_hex'])
        return {k: from_json(v) for k, v in value.items()}
    return value

examples = [(43, '2b'), (-1, '46'), (-128, '3e80'), (128, '3f0080'),
            (65536, '4000010000'), (4294967296, '410000000100000000'),
            (1.0, '2c3ff0000000000000'), (True, '43'), (False, '44'),
            (None, '45'), ('hi', '826869'), (b'\x00\xff', '322f00ff'),
            ([1, True], 'c20143'), ({'a': 1}, '67816101')]
for value, expected in examples:
    actual = bytes(dumps(value))
    assert actual.hex() == expected, (value, actual.hex(), expected)
    assert loads(actual) == from_json(value)
assert loads(bytes.fromhex('423f800000')) == 1.0
assert loads(bytes.fromhex('323ac3a9')) == 'é'
assert loads(bytes.fromhex('3b01437f')) == (1, True)
assert loads(bytes.fromhex('3c8161017f')) == {'a': 1}

for path in sys.argv[1:]:
    with open(path, encoding='utf8') as f:
        vectors = json.load(f)
    for vector in vectors['packets']:
        frame = bytes.fromhex(vector['sanitized_frame_hex'])
        magic, flags, level, index, length = struct.unpack('!cBBBI', frame[:8])
        assert (magic, flags, level, index, length) == (b'P', 16, 0, 0, len(frame) - 8)
        assert loads(frame[8:]) == from_json(vector['packet'])
    print(f'{path}: {len(vectors["packets"])} sanitized frames verified')
print(f'{len(examples) + 4} rencodeplus examples verified')
