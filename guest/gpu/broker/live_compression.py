"""Broker-to-phone compressed DATA records (CGLZ).

Algorithm 1 compresses each envelope alone with raw DEFLATE. Algorithm 2 compresses every
DATA envelope of a session into one zstd stream, each record ending at a flush point.
"""
import struct
import zlib
import live_zstd
from live_protocol import HEADER, Envelope, Kind, ProtocolError, encode

MAX_DECODED = 65600
DEFLATE, ZSTD_STREAM = 1, 2
CONFIG = struct.pack("<II", DEFLATE, MAX_DECODED)
CONFIG_ZSTD_STREAM = struct.pack("<II", ZSTD_STREAM, MAX_DECODED)
OUTER = struct.Struct("<4sHHII")


def _check_data(frame):
    if not HEADER.size < len(frame) <= MAX_DECODED:
        raise ProtocolError("compression DATA limit")
    magic, version, kind, length, reserved, executor, generation, process, stream, sequence = HEADER.unpack_from(frame)
    if (magic != b"CGLV" or version != 1 or kind != Kind.DATA or reserved or
            length != len(frame) - HEADER.size):
        raise ProtocolError("compression requires one complete DATA envelope")
    # Retain all identity/sequence checks without imposing a new sequence domain.
    encode(Envelope(Kind.DATA, executor, generation, process, stream, sequence, frame[HEADER.size:]))


def compress_data(frame):
    """Return a smaller CGLZ message, or the original complete CGLV DATA frame."""
    _check_data(frame)
    compressor = zlib.compressobj(level=1, wbits=-15)
    compressed = compressor.compress(frame) + compressor.flush()
    if OUTER.size + len(compressed) >= len(frame):
        return frame
    return OUTER.pack(b"CGLZ", 1, DEFLATE, len(frame), len(compressed)) + compressed


class StreamCompressor:
    """Algorithm 2: one per session. Every DATA envelope becomes a record, in sequence order:
    each record continues the stream the earlier ones began, so none may be skipped."""

    def __init__(self, level=3):
        self._stream = live_zstd.Compressor(level)

    def compress_data(self, frame):
        _check_data(frame)
        compressed = self._stream.compress(frame)
        return OUTER.pack(b"CGLZ", 1, ZSTD_STREAM, len(frame), len(compressed)) + compressed


class StreamDecompressor:
    """The phone's side of algorithm 2, for tests and measurement."""

    def __init__(self):
        self._stream = live_zstd.Decompressor()

    def decompress(self, record):
        if len(record) < OUTER.size:
            raise ValueError("CGLZ header")
        magic, version, algorithm, decoded, compressed = OUTER.unpack_from(record)
        if (magic != b"CGLZ" or version != 1 or algorithm != ZSTD_STREAM or
                not HEADER.size < decoded <= MAX_DECODED or compressed != len(record) - OUTER.size):
            raise ValueError("CGLZ header")
        return self._stream.decompress(record[OUTER.size:], decoded)
