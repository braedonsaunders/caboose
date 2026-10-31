import json
from pathlib import Path
import struct
import unittest

from live_protocol import Decoder, Envelope, Kind, encode
from live_surface_protocol import validate_surface

VECTORS = json.loads(Path(__file__).with_name("live-swapchain-vectors.json").read_text())
BY_NAME = {v["name"]: v for v in VECTORS}
EXECUTOR = bytes.fromhex("00112233445566778899aabbccddeeff")


class SwapchainWireTests(unittest.TestCase):
    def test_golden_every_split_and_exact_size(self):
        for vector in VECTORS:
            payload, wire = bytes.fromhex(vector["payload"]), bytes.fromhex(vector["wire"])
            kind = Kind[vector["kind"]]
            frame = Envelope(kind, EXECUTOR, 7, 11, 0, 1, payload)
            self.assertEqual(encode(frame), wire)
            for split in range(len(wire) + 1):
                got, parser = [], Decoder(EXECUTOR, 7)
                parser.feed(wire[:split], got.append)
                parser.feed(wire[split:], got.append)
                parser.finish()
                self.assertEqual(got, [frame])
            for invalid in (payload[:-1], payload + b"\0"):
                with self.assertRaises(ValueError):
                    validate_surface(kind, invalid)

    def test_invalid_results_cannot_publish_indices_or_resources(self):
        mutations = [
            ("create", 40, bytes(8)), ("create", 80, bytes(4)),
            ("create", 108, struct.pack('<I', 2)),
            ("create", 112, struct.pack('<I', 1)),
            ("created", 60, bytes(4)), ("created", 72, struct.pack('<I', 257)),
            ("create-error", 48, struct.pack('<Q', 5)),
            ("map", 64, struct.pack('<Q', 15)),
            ("map", 52, struct.pack('<I', 1)),
            ("acquire", 56, bytes(8)), ("acquire", 80, struct.pack('<I', 2)),
            ("acquired", 60, bytes(4)), ("acquired", 76, struct.pack('<I', 256)),
            ("acquire-not-ready", 72, struct.pack('<I', 1)),
            ("acquire-local-timeout", 56, bytes(4)),
            ("acquire-local-timeout", 80, bytes(4)),
            ("acquired", 80, struct.pack('<I', 1)),
            ("indexed-present", 72, struct.pack('<I', 1000001002)),
            ("indexed-present", 88, struct.pack('<Q', 29)),
            ("ordered-present", 64, bytes(8)),
            ("ordered-present", 80, struct.pack('<I', 2)),
            ("ordered-present", 96, struct.pack('<Q', 29)),
            ("owner-revoke", 16, bytes(16)),
        ]
        for name, offset, replacement in mutations:
            with self.subTest(name=name, offset=offset):
                vector = BY_NAME[name]
                body = bytearray.fromhex(vector["payload"])
                body[offset:offset + len(replacement)] = replacement
                parser = Decoder(EXECUTOR, 7)
                with self.assertRaises(ValueError):
                    parser.feed(bytes.fromhex(vector["wire"][:128]) + body,
                                lambda _: self.fail("invalid control delivered"))
                with self.assertRaises(ValueError):
                    parser.feed(b"", lambda _: None)

    def test_real_suboptimal_acquisition_has_index(self):
        body = bytearray.fromhex(BY_NAME["acquired"]["payload"])
        struct.pack_into('<i', body, 64, 1000001003)
        validate_surface(30, body)


if __name__ == "__main__":
    unittest.main()
