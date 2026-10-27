#!/usr/bin/env python3
"""Extract the first H.264 draw from a controlled synthetic capture."""
import json
import struct
import sys
from xpra.net.rencodeplus.rencodeplus import dumps
from extract import decode_stream, json_value

with open(sys.argv[1], encoding='utf8') as f:
    records = json.load(f)
for packet in decode_stream(records, 'server'):
    if packet[0] == 'draw' and packet[6] == 'h264':
        if packet[10].get('frame') != 0:
            raise ValueError('first captured video packet does not start a stream')
        payload = bytes(dumps(packet))
        frame = struct.pack('!cBBBI', b'P', 16, 0, 0, len(payload)) + payload
        print(json.dumps({'source': 'Xpra 6.5.5 x264 captured WebSocket session',
                          'note': 'Decoded and re-encoded; not the original wire frame.',
                          'packets': [{'direction': 'server', 'packet': json_value(packet),
                                       'sanitized_frame_hex': frame.hex()}]}, indent=2))
        break
else:
    raise ValueError('no H.264 draw observed')
