"""Writes live-zstd-stream-vectors.json, the phone's fixtures for CGLZ algorithm 2.

The records depend on the libzstd that makes them; any zstd 1.5 decoder decodes them.
"""
import json
from pathlib import Path
import random
import struct
from live_compression import OUTER, StreamCompressor
from live_protocol import Envelope, Kind, encode

IDENTITY = bytes(range(1, 17))


def vectors():
    rng = random.Random(2026)
    command = b''.join(struct.pack('<IIQQ', 20000 + i % 7, 24, 0xCA00000100000000 + i % 5, i % 3) for i in range(400))
    payloads = [
        ('commands', 1, 1, command),
        ('commands-again', 1, 1, command[:4000] + b'\x01' + command[4001:]),  # matches the record before it
        ('other-stream', 1, 2, bytes(3000)),
        ('incompressible', 1, 1, rng.randbytes(2048)),  # a record larger than its envelope
        ('max-data', 2, 3, (command * 7)[:65536]),
    ]
    compressor = StreamCompressor()
    sequence = []
    for number, (name, process, stream, payload) in enumerate(payloads, 1):
        raw = encode(Envelope(Kind.DATA, IDENTITY, 1, process, stream, number, payload))
        sequence.append({'name': name, 'decoded_hex': raw.hex(), 'wire_hex': compressor.compress_data(raw).hex()})
    first = bytes.fromhex(sequence[0]['wire_hex'])
    magic, version, algorithm, decoded, compressed = OUTER.unpack_from(first)
    body = first[OUTER.size:]

    def record(body=body, version=version, algorithm=algorithm, decoded=decoded, compressed=None):
        return OUTER.pack(magic, version, algorithm, decoded, len(body) if compressed is None else compressed) + body

    # A frame header asking for a 16 MiB window (window descriptor 0x70), above the limit.
    wide = bytes.fromhex('28b52ffd') + bytes([0x00, 0x70]) + bytes.fromhex('010000')
    invalid = [
        ('truncated-header', first[:OUTER.size - 1]),
        ('wrong-version', record(version=2)),
        ('wrong-algorithm', record(algorithm=1)),
        ('decoded-too-small', record(decoded=64)),
        ('decoded-too-large', record(decoded=65601)),
        ('decoded-size-short', record(decoded=decoded - 1)),
        ('decoded-size-long', record(decoded=decoded + 1)),
        ('compressed-size-mismatch', record(compressed=len(body) + 1)),
        ('truncated-stream', record(body=body[:-3])),
        ('trailing-byte', record(body=body + b'\x00')),
        ('window-too-large', record(body=wide, decoded=65)),
    ]
    return {
        'format': 'CGLZ-v1 algorithm 2 (zstd-stream)',
        'note': 'Decode `sequence` in order on one decoder: each record continues the stream of '
                'the records before it. Each `invalid` record is the first record of a fresh decoder.',
        'sequence': sequence,
        'invalid': [{'name': name, 'wire_hex': wire.hex()} for name, wire in invalid],
    }


if __name__ == '__main__':
    path = Path(__file__).with_name('live-zstd-stream-vectors.json')
    path.write_text(json.dumps(vectors(), indent=1) + '\n')
