import struct
import unittest
import json
from pathlib import Path

import surface_local_protocol as protocol


def request(kind, body):
    return protocol.HEADER.pack(b'CGLS', 1, kind, 16 + len(body), 0) + body


class LocalSurfaceProtocolTests(unittest.TestCase):
    def test_indexed_records_preserve_native_payloads_and_request_scope(self):
        vectors = json.loads((Path(__file__).parents[1] / 'broker/live-swapchain-vectors.json').read_text())
        for vector in vectors:
            wire = bytes.fromhex(vector['wire'])
            kind = struct.unpack_from('<H', wire, 6)[0]
            payload = bytes.fromhex(vector['payload'])
            if kind in (25, 27, 29, 31, 32, 34):
                self.assertEqual(protocol.decode_request(request(kind, payload[40:])),
                                 (kind, payload[40:]))
                with self.assertRaises(ValueError):
                    protocol.encode_reply(kind, payload)
            else:
                self.assertEqual(protocol.encode_reply(kind, payload), request(kind, payload))
                with self.assertRaises(ValueError):
                    protocol.decode_request(request(kind, payload[40:]))

    def test_bind_preserves_zero_or_asserted_extent(self):
        for width, height in ((0, 0), (1280, 720)):
            body = struct.pack('<QIIII', 7, 9, width, height, 0)
            self.assertEqual(protocol.decode_request(request(16, body)), (16, body))
        for width, height in ((0, 720), (1280, 0)):
            with self.assertRaises(ValueError):
                protocol.decode_request(request(16, struct.pack('<QIIII', 7, 9, width, height, 0)))

    def test_bind_names_a_wayland_surface_or_an_x11_window(self):
        for space in (0, 1):
            body = struct.pack('<QIIII', 7, 0x400003, 0, 0, space)
            self.assertEqual(protocol.decode_request(request(16, body)), (16, body))
        for space in (2, 0xFFFFFFFF):
            with self.assertRaises(ValueError):
                protocol.decode_request(request(16, struct.pack('<QIIII', 7, 9, 0, 0, space)))

    def test_bad_headers_and_truncated_requests_fail(self):
        valid = request(18, struct.pack('<QQ', 1, 2))
        for cut in range(len(valid)):
            with self.assertRaises(ValueError): protocol.decode_request(valid[:cut])
        for bad in (b'bad!' + valid[4:], valid[:12] + b'\x01\0\0\0' + valid[16:], request(99, b'')):
            with self.assertRaises(ValueError): protocol.decode_request(bad)

    def test_present_checks_layout_and_duplicate_waits(self):
        base = struct.pack('<QQQQIIIIII', 1, 2, 3, 4, 37, 10, 10, 1, 0, 2)
        with self.assertRaises(ValueError):
            protocol.decode_request(request(20, base + struct.pack('<QQ', 5, 5)))
        good = base + struct.pack('<QQ', 5, 6)
        self.assertEqual(protocol.decode_request(request(20, good)), (20, good))

    def test_terminal_error_is_not_vulkan_success(self):
        reply = protocol.encode_reply(0x7fff, struct.pack('<iIiI', 32, 0, 0, 0))
        self.assertEqual(len(reply), 32)
        for body in (struct.pack('<iIiI', 0, 0, 0, 0), struct.pack('<iIiI', 1, 1, 0, 0)):
            with self.assertRaises(ValueError): protocol.encode_reply(0x7fff, body)


if __name__ == '__main__': unittest.main()
