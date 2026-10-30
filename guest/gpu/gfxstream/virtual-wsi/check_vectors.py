#!/usr/bin/env python3
"""Exercise a compiled C++ decoder with frozen, independently authored CGLV vectors."""
import json
from pathlib import Path
import struct
import subprocess
import sys

vectors = json.loads((Path(__file__).resolve().parents[2] / 'broker/live-surface-vectors.json').read_text())
packets = []
expected = []
for vector in vectors:
    raw = bytes.fromhex(vector['wire'])
    kind = struct.unpack_from('<H', raw, 6)[0]
    if kind not in (17, 19, 21, 22, 24):
        continue
    body = bytes.fromhex(vector['payload'])
    if kind == 17:
        body = struct.pack('<Q', 5) + body
    packet = struct.pack('<4sHHII', b'CGLS', 1, kind, 16 + len(body), 0) + body
    packets.append(packet.hex())
    expected.append(str(kind))
    for cut in range(len(packet)):
        packets.append(packet[:cut].hex() or '00')
        expected.append('reject')
    for offset in (0, 4, 12):
        mutated = bytearray(packet)
        mutated[offset] ^= 0x80
        packets.append(mutated.hex())
        expected.append('reject')
    packets.append((packet + b'\0').hex())
    expected.append('reject')
result = subprocess.run([sys.argv[1], '--decode'], input='\n'.join(packets) + '\n',
                        text=True, capture_output=True, check=True, timeout=10)
actual = result.stdout.splitlines()
assert actual == expected, [(i, a, e) for i, (a, e) in enumerate(zip(actual, expected)) if a != e][:5]
print(f'{len(packets)} independent-vector and malformed-record checks passed')
