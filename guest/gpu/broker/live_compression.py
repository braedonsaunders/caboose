"""Independent, bounded broker-to-phone raw DEFLATE frames."""
import struct
import zlib
from live_protocol import HEADER, Envelope, Kind, ProtocolError, encode

MAX_DECODED = 65600
CONFIG = struct.pack("<II", 1, MAX_DECODED)
OUTER = struct.Struct("<4sHHII")


def compress_data(frame):
    """Return a smaller CGLZ message, or the original complete CGLV DATA frame."""
    if not HEADER.size < len(frame) <= MAX_DECODED:
        raise ProtocolError("compression DATA limit")
    magic, version, kind, length, reserved, executor, generation, process, stream, sequence = HEADER.unpack_from(frame)
    if (magic != b"CGLV" or version != 1 or kind != Kind.DATA or reserved or
            length != len(frame) - HEADER.size):
        raise ProtocolError("compression requires one complete DATA envelope")
    # Retain all identity/sequence checks without imposing a new sequence domain.
    encode(Envelope(Kind.DATA, executor, generation, process, stream, sequence, frame[HEADER.size:]))
    compressor = zlib.compressobj(level=1, wbits=-15)
    compressed = compressor.compress(frame) + compressor.flush()
    if OUTER.size + len(compressed) >= len(frame):
        return frame
    return OUTER.pack(b"CGLZ", 1, 1, len(frame), len(compressed)) + compressed
