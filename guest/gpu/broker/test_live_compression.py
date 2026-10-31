"""Independent byte fixtures also consumed by the phone's transport tests."""
import json
from pathlib import Path
import random
import struct
import unittest
import zlib
from live_compression import CONFIG, MAX_DECODED, compress_data
from live_protocol import Decoder, Envelope, Kind, ProtocolError, encode

IDENTITY = bytes(range(1, 17))
VECTORS = json.loads(Path(__file__).with_name('live-compression-vectors.json').read_text())


def reference_decode(wire):
    # Receiver oracle only; the broker never accepts compressed incoming frames.
    if len(wire) < 16: raise ValueError('header')
    magic, version, algorithm, decoded, compressed = struct.unpack_from('<4sHHII', wire)
    if (magic != b'CGLZ' or version != 1 or algorithm != 1 or
            not 1 <= decoded <= 65600 or compressed != len(wire) - 16):
        raise ValueError('header')
    inflater = zlib.decompressobj(-15)
    raw = inflater.decompress(wire[16:], decoded + 1)
    if len(raw) != decoded or not inflater.eof or inflater.unused_data or inflater.unconsumed_tail:
        raise ValueError('deflate boundary')
    got = []
    parser = Decoder(IDENTITY, 1)
    parser.feed(raw, got.append); parser.finish()
    if len(got) != 1 or got[0].kind != Kind.DATA or not 1 <= len(got[0].payload) <= 65536:
        raise ValueError('DATA boundary')
    return raw


class CompressionTests(unittest.TestCase):
    def test_independent_vectors_preserve_complete_original_bytes(self):
        for vector in VECTORS['valid']:
            with self.subTest(vector=vector['name']):
                original = bytes.fromhex(vector['decoded_hex'])
                wire = bytes.fromhex(vector['wire_hex'])
                self.assertEqual(reference_decode(wire), original)
                self.assertEqual(compress_data(original), wire)
                self.assertLess(len(wire), len(original))

    def test_malformed_receiver_vectors(self):
        for vector in VECTORS['invalid']:
            with self.subTest(vector=vector['name']):
                with self.assertRaises((ValueError, zlib.error)):
                    reference_decode(bytes.fromhex(vector['wire_hex']))

    def test_control_vectors_and_strict_scope_payload(self):
        for vector in VECTORS['controls']:
            kind = Kind(vector['kind'])
            message = Envelope(kind, IDENTITY, 1, 0, 0, 1, CONFIG)
            self.assertEqual(encode(message).hex(), vector['wire_hex'])
            got=[]; parser=Decoder(IDENTITY,1)
            parser.feed(bytes.fromhex(vector['wire_hex']),got.append); parser.finish()
            self.assertEqual(got,[message])
            for process,stream,payload in [(1,0,CONFIG),(0,1,CONFIG),(0,0,b''),(0,0,struct.pack('<II',2,65600)),(0,0,struct.pack('<II',1,65601))]:
                with self.assertRaises(ProtocolError):
                    encode(Envelope(kind,IDENTITY,1,process,stream,1,payload))
                wire=struct.pack('<4sHHII16sQQQQ',b'CGLV',1,kind,len(payload),0,IDENTITY,1,process,stream,1)+payload
                with self.assertRaises(ProtocolError): Decoder(IDENTITY,1).feed(wire,lambda _:None)

    def test_incompressible_fallback_and_no_dictionary(self):
        payload = random.Random(314159).randbytes(65536)
        raw = encode(Envelope(Kind.DATA,IDENTITY,1,2,3,1,payload))
        self.assertEqual(compress_data(raw), raw)
        original=bytes.fromhex(VECTORS['valid'][0]['decoded_hex'])
        self.assertEqual(compress_data(original),compress_data(original))

    def test_encoder_rejects_non_data_or_out_of_bounds(self):
        for raw in [b'', encode(Envelope(Kind.FIN,IDENTITY,1,2,3,1)),
                    encode(Envelope(Kind.DATA,IDENTITY,1,2,3,1,b'x'*65537))]:
            with self.assertRaises(ProtocolError): compress_data(raw)

if __name__ == '__main__': unittest.main()
