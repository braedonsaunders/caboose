#!/usr/bin/env python3
"""Extract redacted, re-encoded examples from a local capture.py JSON stream.

Run with the Python shipped by Xpra 6.5.5. Never commit the input capture.
"""
import collections
import json
import struct
import sys

from xpra.net.compression import decompress_by_name, init_all
from xpra.net.rencodeplus.rencodeplus import dumps, loads

init_all()


def decode_stream(records, direction):
    stream = bytes.fromhex(''.join(r['hex'] for r in records if r['direction'] == direction))
    _, stream = stream.split(b'\r\n\r\n', 1)
    xpra = bytearray()
    while len(stream) >= 2:
        opcode, length = stream[0] & 15, stream[1] & 127
        masked, pos = stream[1] & 128, 2
        if length == 126:
            length = struct.unpack('!H', stream[pos:pos + 2])[0]; pos += 2
        elif length == 127:
            length = struct.unpack('!Q', stream[pos:pos + 8])[0]; pos += 8
        mask = stream[pos:pos + 4] if masked else b''
        pos += 4 if masked else 0
        if len(stream) < pos + length:
            raise ValueError('truncated WebSocket frame')
        payload, stream = stream[pos:pos + length], stream[pos + length:]
        if masked:
            payload = bytes(value ^ mask[i % 4] for i, value in enumerate(payload))
        if opcode in (0, 2):
            xpra.extend(payload)
    if stream:
        raise ValueError('truncated WebSocket header')
    chunks = {}
    while len(xpra) >= 8:
        magic, flags, level, index, size = struct.unpack('!cBBBI', xpra[:8])
        if magic != b'P' or len(xpra) < 8 + size:
            raise ValueError('invalid or truncated Xpra frame')
        payload = bytes(xpra[8:8 + size]); del xpra[:8 + size]
        if level:
            algorithm = 'lz4' if level & 0x10 else 'brotli' if level & 0x40 else None
            if not algorithm:
                raise ValueError('unsupported compression')
            payload = bytes(decompress_by_name(payload, algorithm))
        if index:
            if index in chunks:
                raise ValueError('duplicate raw chunk')
            chunks[index] = payload
            continue
        if not flags & 0x10:
            raise ValueError('not rencodeplus')
        packet = list(loads(payload))
        for i, data in chunks.items():
            packet[i] = data
        chunks.clear()
        yield packet
    if xpra or chunks:
        raise ValueError('incomplete Xpra stream')


def json_value(value):
    if isinstance(value, (bytes, memoryview)):
        return {'bytes_hex': bytes(value).hex()}
    if isinstance(value, (list, tuple)):
        return [json_value(x) for x in value]
    if isinstance(value, dict):
        return {str(k): json_value(v) for k, v in value.items()}
    return value


def main():
    records = json.load(open(sys.argv[1], encoding='utf8'))
    chosen = []
    count = collections.Counter()
    wanted = {'hello', 'new-window', 'window-metadata', 'key-action', 'draw',
              'clipboard-token', 'clipboard-request', 'clipboard-contents'}
    hello_allow = {'version', 'protocol', 'encoders', 'compressors', 'rencodeplus',
                   'lz4', 'brotli', 'desktop_size', 'dpi', 'windows'}
    metadata_allow = {'title', 'class-instance', 'window-type', 'size-constraints',
                      'focused', 'icon-title'}
    for direction in ('client', 'server'):
        for packet in decode_stream(records, direction):
            name = packet[0]
            if name not in wanted:
                continue
            discriminator = (direction, name, packet[6] if name == 'draw' else '')
            if count[discriminator]:
                continue
            count[discriminator] += 1
            if name == 'hello':
                packet[1] = {k: v for k, v in packet[1].items() if k in hello_allow}
            elif name == 'new-window':
                packet[6] = {k: v for k, v in packet[6].items() if k in metadata_allow}
                packet[7] = {}
            elif name == 'window-metadata':
                packet[2] = {k: v for k, v in packet[2].items() if k in metadata_allow}
            payload = bytes(dumps(packet))
            frame = struct.pack('!cBBBI', b'P', 0x10, 0, 0, len(payload)) + payload
            chosen.append({'direction': direction, 'packet': json_value(packet),
                           'sanitized_frame_hex': frame.hex()})
    observed = {(item['direction'], item['packet'][0]) for item in chosen}
    required = {('client', 'hello'), ('server', 'hello'), ('client', 'key-action'),
                ('server', 'new-window'), ('server', 'window-metadata'),
                ('server', 'draw'), ('client', 'clipboard-token'),
                ('server', 'clipboard-request'), ('client', 'clipboard-contents')}
    if missing := required - observed:
        raise ValueError(f'capture missing required events: {sorted(missing)}')
    print(json.dumps({'source': 'Xpra 6.5.5 captured WebSocket session',
                      'note': 'Decoded, redacted and re-encoded; these are not original wire frames.',
                      'packets': chosen}, indent=2))


if __name__ == '__main__':
    main()
