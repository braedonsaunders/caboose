#!/usr/bin/env python3
"""Check fixture integrity and that the concurrency test's prefix contains a frame.

Parse only public GFXR file/block/frame-marker headers; never print trace payloads.
This structural check is independent of the player and does not prove native replay.
"""
import hashlib
from pathlib import Path
import struct

capture = (Path(__file__).parent / 'fixtures/vkcube.gfxr').read_bytes()
assert len(capture) == 1710239
assert hashlib.sha256(capture).hexdigest() == '90db2232be2940106b852eb8af5959872c1d2d2cc69dedccc57d981bcbaae123'
magic, major, minor, options = struct.unpack_from('<4sIII', capture)
assert (magic, major, minor) == (b'GFXR', 0, 1)
offset = 16 + options * 8
ends = []
while offset < len(capture):
    size, kind = struct.unpack_from('<QI', capture, offset)
    end = offset + 12 + size
    assert end <= len(capture), 'truncated block'
    assert kind in (1, 3, 4, 5), 'unexpected or compressed block'
    if kind == 1:
        marker, frame = struct.unpack_from('<IQ', capture, offset + 12)
        assert marker == 2
        ends.append((frame, end))
    offset = end
assert offset == len(capture)
assert [frame for frame, _ in ends] == list(range(1, 301))
assert ends[0][1] < len(capture) // 2, 'concurrent first replay cannot present from its prefix'
print('Fixture integrity, 300 complete frame markers, first frame before half-prefix: PASS')
