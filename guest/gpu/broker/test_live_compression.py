"""Independent byte fixtures also consumed by the phone's transport tests."""
import json
from pathlib import Path
import random
import struct
import unittest
import zlib
from live_compression import (CONFIG, CONFIG_ZSTD_STREAM, MAX_DECODED, StreamCompressor, StreamDecompressor, compress_data,
                              zstd_stream_config, zstd_stream_window)
import live_zstd
from live_protocol import Decoder, Envelope, Kind, ProtocolError, encode

IDENTITY = bytes(range(1, 17))
VECTORS = json.loads(Path(__file__).with_name('live-compression-vectors.json').read_text())
STREAM_VECTORS = json.loads(Path(__file__).with_name('live-zstd-stream-vectors.json').read_text())


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
            for process,stream,payload in [(1,0,CONFIG),(0,1,CONFIG),(0,0,b''),(0,0,struct.pack('<II',3,65600)),(0,0,struct.pack('<II',2,65600)),(0,0,struct.pack('<IIII',2,65600,31,0)),(0,0,struct.pack('<IIII',2,65600,19,0)),(0,0,struct.pack('<IIII',2,65600,26,1)),(0,0,struct.pack('<IIII',2,65601,26,0)),(0,0,struct.pack('<IIII',1,65600,26,0)),(0,0,struct.pack('<II',1,65601))]:
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

@unittest.skipUnless(live_zstd.available(), 'libzstd 1.5 is not installed')
class StreamCompressionTests(unittest.TestCase):
    def test_sequence_vectors_decode_in_order_on_one_decoder(self):
        decoder, parser = StreamDecompressor(), Decoder(IDENTITY, 1)
        for vector in STREAM_VECTORS['sequence']:
            with self.subTest(vector=vector['name']):
                raw = decoder.decompress(bytes.fromhex(vector['wire_hex']))
                self.assertEqual(raw, bytes.fromhex(vector['decoded_hex']))
                got = []
                parser.feed(raw, got.append)
                self.assertEqual([envelope.kind for envelope in got], [Kind.DATA])
        parser.finish()

    def test_invalid_vectors(self):
        for vector in STREAM_VECTORS['invalid']:
            with self.subTest(vector=vector['name']):
                with self.assertRaises(ValueError):
                    StreamDecompressor().decompress(bytes.fromhex(vector['wire_hex']))

    def test_vectors_are_what_the_generator_makes(self):
        from make_zstd_stream_vectors import vectors
        generated = vectors()
        # The compressed bytes belong to the libzstd that made them; the decoded ones do not.
        self.assertEqual([v['decoded_hex'] for v in generated['sequence']],
                         [v['decoded_hex'] for v in STREAM_VECTORS['sequence']])
        self.assertEqual([v['name'] for v in generated['invalid']], [v['name'] for v in STREAM_VECTORS['invalid']])

    def test_every_data_envelope_is_a_record_continuing_the_stream(self):
        rng = random.Random(7)
        compressor, decoder = StreamCompressor(), StreamDecompressor()
        sizes = []
        repeated = rng.randbytes(30000)
        for sequence, payload in enumerate([repeated, rng.randbytes(65536), repeated, b'x', repeated], 1):
            raw = encode(Envelope(Kind.DATA, IDENTITY, 1, 2, 3, sequence, payload))
            record = compressor.compress_data(raw)
            self.assertEqual(record[:4], b'CGLZ')
            self.assertEqual(decoder.decompress(record), raw)
            sizes.append(len(record))
        self.assertGreater(sizes[1], 65600)  # incompressible: still a record, larger than its envelope
        self.assertLess(sizes[2], 200)  # matched in the stream's window
        self.assertLess(sizes[4], 200)

    def test_a_skipped_record_breaks_the_stream(self):
        compressor = StreamCompressor()
        payload = random.Random(9).randbytes(20000)
        records = [compressor.compress_data(encode(Envelope(Kind.DATA, IDENTITY, 1, 2, 3, n, payload))) for n in (1, 2)]
        with self.assertRaises(ValueError):
            StreamDecompressor().decompress(records[1])

    def test_encoder_rejects_non_data_or_out_of_bounds(self):
        compressor = StreamCompressor()
        for raw in [b'', encode(Envelope(Kind.FIN, IDENTITY, 1, 2, 3, 1)),
                    encode(Envelope(Kind.DATA, IDENTITY, 1, 2, 3, 1, b'x' * 65537))]:
            with self.assertRaises(ProtocolError): compressor.compress_data(raw)

    def test_configuration_names_the_window(self):
        self.assertEqual(CONFIG_ZSTD_STREAM, struct.pack('<IIII', 2, MAX_DECODED, 27, 0))
        for vector in STREAM_VECTORS['transport']['valid']:
            config, ready = bytes.fromhex(vector['config_hex']), bytes.fromhex(vector['ready_hex'])
            self.assertEqual(zstd_stream_window(config, ready), vector['window_log'])
            for payload, kind in ((config, Kind.TRANSPORT_CONFIG), (ready, Kind.TRANSPORT_READY)):
                encode(Envelope(kind, IDENTITY, 1, 0, 0, 1, payload))
        for vector in STREAM_VECTORS['transport']['invalid']:
            with self.subTest(vector=vector['name']):
                self.assertIsNone(zstd_stream_window(bytes.fromhex(vector['config_hex']), bytes.fromhex(vector['ready_hex'])))

    def test_a_larger_window_finds_what_repeats_far_back(self):
        rng = random.Random(11)
        image = rng.randbytes(60000)
        filler = [rng.randbytes(65000) for _ in range(200)]  # 13 MB: beyond an 8 MiB window
        sizes = {}
        for window_log in (23, 26):
            compressor, decoder = StreamCompressor(window_log=window_log), StreamDecompressor(window_log)
            sequence, last = 1, 0
            for payload in [image] + filler + [image]:
                record = compressor.compress_data(encode(Envelope(Kind.DATA, IDENTITY, 1, 2, 3, sequence, payload)))
                self.assertEqual(decoder.decompress(record)[64:], payload)
                sequence, last = sequence + 1, len(record)
            sizes[window_log] = last
        self.assertGreater(sizes[23], 60000)
        self.assertLess(sizes[26], 1000)
        with self.assertRaises(ValueError):  # a 64 MiB stream on an 8 MiB decoder
            StreamDecompressor(23).decompress(StreamCompressor(window_log=26).compress_data(
                encode(Envelope(Kind.DATA, IDENTITY, 1, 2, 3, 1, image))))


if __name__ == '__main__': unittest.main()
