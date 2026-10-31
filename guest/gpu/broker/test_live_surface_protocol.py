import json
from pathlib import Path
import struct
import unittest

from live_protocol import Decoder, Envelope, HEADER, Kind, encode
from live_surface_protocol import validate_surface

VECTORS = json.loads(Path(__file__).with_name("live-surface-vectors.json").read_text())
BY_NAME = {v["name"]: v for v in VECTORS}
IDENTITY = bytes.fromhex("00112233445566778899aabbccddeeff")


class SurfaceWireTests(unittest.TestCase):
    def test_golden_and_every_transport_split(self):
        for v in VECTORS:
            wire, payload = bytes.fromhex(v["wire"]), bytes.fromhex(v["payload"])
            frame = Envelope(Kind[v["kind"]], IDENTITY, 7, 11, 0, 1, payload)
            self.assertEqual(encode(frame), wire, v["name"])
            for split in range(len(wire) + 1):
                got, decoder = [], Decoder(IDENTITY, 7)
                decoder.feed(wire[:split], got.append)
                decoder.feed(wire[split:], got.append)
                decoder.finish()
                self.assertEqual(got, [frame])

    def test_invalid_fields_fail_before_delivery_and_poison(self):
        mutations = [
            ("bind", 0, bytes(16)), ("bind", 16, bytes(16)),
            ("bind", 32, bytes(8)), ("bind", 40, bytes(8)),
            ("bind", 56, bytes(4)), ("bind", 60, bytes(4)),
            ("bound", 40, struct.pack('<i', -1)),
            ("bound", 44, struct.pack('<I', 2)), ("bound", 52, struct.pack('<I', 1)),
            ("caps", 116, struct.pack('<I', 4097)),
            ("caps", 148, bytes(4)), ("caps", 152, struct.pack('<I', 2)),
            ("present", 40, bytes(8)), ("present", 72, bytes(4)),
            ("present", 84, struct.pack('<I', 1000001002)),
            ("present", 92, struct.pack('<I', 65)),
            ("present", 104, struct.pack('<Q', 17)),
            ("device-lost", 56, struct.pack('<i', -3)),
            ("queued", 64, struct.pack('<I', 3)),
            ("released", 40, bytes(8)),
        ]
        for name, offset, replacement in mutations:
            with self.subTest(name=name, offset=offset):
                v = BY_NAME[name]
                body = bytearray.fromhex(v["payload"])
                body[offset:offset + len(replacement)] = replacement
                wire = bytes.fromhex(v["wire"][:128]) + body
                decoder = Decoder(IDENTITY, 7)
                with self.assertRaises(ValueError):
                    decoder.feed(wire, lambda _: self.fail("invalid control delivered"))
                with self.assertRaises(ValueError):
                    decoder.feed(b"", lambda _: None)

    def test_capabilities_cannot_claim_success_without_actual_result(self):
        body = bytearray.fromhex(BY_NAME["caps-error"]["payload"])
        body[48:64] = bytes(16)
        with self.assertRaises(ValueError):
            validate_surface(19, body)

    def test_exact_payload_lengths_and_process_scope(self):
        for v in VECTORS:
            kind, body = Kind[v["kind"]], bytes.fromhex(v["payload"])
            for bad in (body[:-1], body + b"\x00"):
                with self.assertRaises(ValueError):
                    validate_surface(kind, bad)
            with self.assertRaises(ValueError):
                encode(Envelope(kind, IDENTITY, 7, 11, 5, 1, body))
        for reserved in (14, 15):
            with self.assertRaises(ValueError):
                Decoder(IDENTITY, 7).feed(HEADER.pack(b'CGLV', 1, reserved, 0, 0,
                                                  IDENTITY, 7, 11, 0, 1), lambda _: None)


if __name__ == "__main__":
    unittest.main()
