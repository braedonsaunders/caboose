import dataclasses
import json
from pathlib import Path
import unittest

from live_protocol import Decoder, Envelope, HEADER, Kind, MAX_MESSAGE, MAX_PAYLOAD, ProtocolError, encode

IDENTITY = bytes.fromhex("00112233445566778899aabbccddeeff")
HELLO = (b"CBGLREF1" + (3).to_bytes(4, "little") + (48).to_bytes(4, "little")
         + bytes.fromhex("20d3bb2e30337cabf0febb006ed102ab25ccf6d9ddbfaf624c7e68f9040969c0"))


def frame(kind=Kind.DATA, sequence=1, payload=b"\x00\xffpayload"):
    return Envelope(kind, IDENTITY, 7, 11, 13, sequence, payload)


class LiveProtocolTests(unittest.TestCase):
    def decoder(self):
        return Decoder(IDENTITY, 7)

    def test_golden_vectors(self):
        vectors = json.loads(Path(__file__).with_name("live-vectors.json").read_text())
        for vector in vectors:
            with self.subTest(kind=vector["kind"]):
                message = Envelope(Kind[vector["kind"]], IDENTITY, 7,
                                   vector["process"], vector["stream"], 1,
                                   bytes.fromhex(vector["payload"]))
                self.assertEqual(encode(message).hex(), vector["wire"])
                got = []
                self.decoder().feed(bytes.fromhex(vector["wire"]), got.append)
                self.assertEqual(got, [message])

    def test_every_split_and_single_bytes(self):
        wire = encode(frame()) + encode(frame(Kind.FIN, 2, b""))
        for split in range(len(wire) + 1):
            decoder, got = self.decoder(), []
            decoder.feed(wire[:split], got.append)
            decoder.feed(wire[split:], got.append)
            decoder.finish()
            self.assertEqual(got, [frame(), frame(Kind.FIN, 2, b"")])
        decoder, got = self.decoder(), []
        for byte in wire:
            decoder.feed(bytes([byte]), got.append)
        self.assertEqual(len(got), 2)

    def test_all_truncated_prefixes_fail_at_eof(self):
        wire = encode(frame())
        for length in range(1, len(wire)):
            decoder = self.decoder()
            decoder.feed(wire[:length], lambda _: self.fail("partial delivered"))
            with self.assertRaises(ProtocolError):
                decoder.finish()

    def test_header_rejection_before_payload_allocation(self):
        valid = list(HEADER.unpack(encode(frame())[:64]))
        for index, replacement in [(0, b"FAIL"), (1, 2), (2, 99), (3, MAX_PAYLOAD + 1),
                                   (4, 1), (5, bytes(16)), (5, b"x" * 16),
                                   (6, 0), (6, 8), (7, 0), (8, 0), (9, 2)]:
            decoder = self.decoder()
            fields = valid.copy()
            fields[index] = replacement
            with self.assertRaises(ProtocolError):
                decoder.feed(HEADER.pack(*fields), lambda _: self.fail("invalid delivered"))
            self.assertEqual(decoder.buffered_bytes, 0)
            with self.assertRaises(ProtocolError):
                decoder.feed(encode(frame()), lambda _: None)

    def test_directional_sequence_replay_and_gap(self):
        for sequence in (1, 3):
            decoder = self.decoder()
            decoder.feed(encode(frame()), lambda _: None)
            with self.assertRaises(ProtocolError):
                decoder.feed(encode(frame(sequence=sequence)), lambda _: None)

    def test_identity_bootstrap_requires_session(self):
        decoder, got = Decoder(), []
        message = Envelope(Kind.SESSION, IDENTITY, 7, 0, 0, 1, HELLO)
        decoder.feed(encode(message), got.append)
        decoder.feed(encode(frame(sequence=2)), got.append)
        self.assertEqual(got, [message, frame(sequence=2)])
        with self.assertRaises(ProtocolError):
            Decoder().feed(encode(frame()), lambda _: None)

    def test_scope_and_control_lengths(self):
        invalid = [frame(Kind.FIN), frame(payload=b""),
                   frame(Kind.PROCESS_OPEN, payload=b""),
                   Envelope(Kind.SESSION, IDENTITY, 7, 0, 0, 1, HELLO[:-1]),
                   Envelope(Kind.REVOKE, IDENTITY, 7, 1, 0, 1),
                   dataclasses.replace(frame(), generation=2**64),
                   dataclasses.replace(frame(), sequence=0)]
        for message in invalid:
            with self.assertRaises(ProtocolError):
                encode(message)

    def test_bound_and_delivery_failure(self):
        message = frame(payload=b"x" * MAX_PAYLOAD)
        wire = encode(message)
        self.assertEqual(len(wire), MAX_MESSAGE)
        decoder, got = self.decoder(), []
        decoder.feed(wire, got.append)
        self.assertEqual(got, [message])
        self.assertEqual(decoder.buffered_bytes, 0)
        with self.assertRaises(ProtocolError):
            self.decoder().feed(wire + b"x", lambda _: None)
        decoder = self.decoder()
        def overflow(_):
            raise BufferError("consumer admission full")
        with self.assertRaises(BufferError):
            decoder.feed(encode(frame()), overflow)
        with self.assertRaises(ProtocolError):
            decoder.feed(b"", lambda _: None)

    def test_end_cannot_reopen(self):
        decoder = self.decoder()
        decoder.finish()
        with self.assertRaises(ProtocolError):
            decoder.feed(b"", lambda _: None)


if __name__ == "__main__":
    unittest.main()
