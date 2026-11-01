"""One zstd stream through the system libzstd, flushed at every message.

The computer's Python predates the standard library's zstd module, so this binds the
streaming API of libzstd 1.5 with ctypes. `Compressor.compress` returns everything needed
to decode its input, given every earlier output of the same compressor; `Decompressor` is
the receiving side, for tests and measurement.
"""
import ctypes
import ctypes.util

WINDOW_LOG = 23  # 8 MiB, the smallest window a phone takes
BLOCK_HEADER = 3

_C_COMPRESSION_LEVEL, _C_WINDOW_LOG, _C_LONG_DISTANCE, _C_CONTENT_SIZE, _C_CHECKSUM = 100, 101, 160, 200, 201
_D_WINDOW_LOG_MAX = 100
_E_FLUSH = 1


class _Buffer(ctypes.Structure):
    _fields_ = [("data", ctypes.c_void_p), ("size", ctypes.c_size_t), ("pos", ctypes.c_size_t)]


def _load():
    for name in ("libzstd.so.1", ctypes.util.find_library("zstd")):
        if not name:
            continue
        try:
            lib = ctypes.CDLL(name)
        except OSError:
            continue
        lib.ZSTD_versionNumber.restype = ctypes.c_uint
        if lib.ZSTD_versionNumber() < 10500:
            continue
        lib.ZSTD_createCCtx.restype = ctypes.c_void_p
        lib.ZSTD_freeCCtx.argtypes = [ctypes.c_void_p]
        lib.ZSTD_CCtx_setParameter.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int]
        lib.ZSTD_CCtx_setParameter.restype = ctypes.c_size_t
        lib.ZSTD_compressStream2.argtypes = [ctypes.c_void_p, ctypes.POINTER(_Buffer), ctypes.POINTER(_Buffer), ctypes.c_int]
        lib.ZSTD_compressStream2.restype = ctypes.c_size_t
        lib.ZSTD_compressBound.argtypes = [ctypes.c_size_t]
        lib.ZSTD_compressBound.restype = ctypes.c_size_t
        lib.ZSTD_createDCtx.restype = ctypes.c_void_p
        lib.ZSTD_freeDCtx.argtypes = [ctypes.c_void_p]
        lib.ZSTD_DCtx_setParameter.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int]
        lib.ZSTD_DCtx_setParameter.restype = ctypes.c_size_t
        lib.ZSTD_decompressStream.argtypes = [ctypes.c_void_p, ctypes.POINTER(_Buffer), ctypes.POINTER(_Buffer)]
        lib.ZSTD_decompressStream.restype = ctypes.c_size_t
        lib.ZSTD_isError.argtypes = [ctypes.c_size_t]
        lib.ZSTD_isError.restype = ctypes.c_uint
        lib.ZSTD_getErrorName.argtypes = [ctypes.c_size_t]
        lib.ZSTD_getErrorName.restype = ctypes.c_char_p
        return lib
    return None


_lib = _load()


def available():
    """Whether libzstd 1.5 or later is present."""
    return _lib is not None


def _check(code):
    if _lib.ZSTD_isError(code):
        raise ValueError("zstd: " + _lib.ZSTD_getErrorName(code).decode())
    return code


class Compressor:
    def __init__(self, level=3, window_log=WINDOW_LOG):
        if _lib is None:
            raise OSError("libzstd 1.5 is not available")
        self._context = _lib.ZSTD_createCCtx()
        if not self._context:
            raise MemoryError("zstd compression context")
        # Beyond the default window, long-distance matching finds what repeats far back
        # (an image uploaded again a minute later).
        for parameter, value in ((_C_COMPRESSION_LEVEL, level), (_C_WINDOW_LOG, window_log),
                                 (_C_LONG_DISTANCE, int(window_log > WINDOW_LOG)),
                                 (_C_CONTENT_SIZE, 0), (_C_CHECKSUM, 0)):
            _check(_lib.ZSTD_CCtx_setParameter(self._context, parameter, value))
        self._capacity = 0
        self._output = None

    def compress(self, data):
        """The next piece of the stream: all of `data`, ending at a flush point."""
        bound = _lib.ZSTD_compressBound(len(data)) + 64
        if bound > self._capacity:
            self._capacity = bound
            self._output = ctypes.create_string_buffer(bound)
        source = ctypes.create_string_buffer(bytes(data), len(data))
        given = _Buffer(ctypes.cast(source, ctypes.c_void_p), len(data), 0)
        taken = _Buffer(ctypes.cast(self._output, ctypes.c_void_p), self._capacity, 0)
        # With room for the bound, one call consumes the input and completes the flush.
        if _check(_lib.ZSTD_compressStream2(self._context, ctypes.byref(taken), ctypes.byref(given), _E_FLUSH)) or given.pos != given.size:
            raise ValueError("zstd: flush incomplete")
        return self._output.raw[:taken.pos]

    def __del__(self):
        if getattr(self, "_context", None):
            _lib.ZSTD_freeCCtx(self._context)
            self._context = None


class Decompressor:
    def __init__(self, window_log_max=WINDOW_LOG):
        if _lib is None:
            raise OSError("libzstd 1.5 is not available")
        self._context = _lib.ZSTD_createDCtx()
        if not self._context:
            raise MemoryError("zstd decompression context")
        _check(_lib.ZSTD_DCtx_setParameter(self._context, _D_WINDOW_LOG_MAX, window_log_max))

    def decompress(self, data, expected):
        """Exactly `expected` bytes from exactly `data`; anything else is an error."""
        source = ctypes.create_string_buffer(bytes(data), len(data))
        output = ctypes.create_string_buffer(expected + 1)
        given = _Buffer(ctypes.cast(source, ctypes.c_void_p), len(data), 0)
        taken = _Buffer(ctypes.cast(output, ctypes.c_void_p), expected + 1, 0)
        hint = 0
        while given.pos < given.size and taken.pos <= expected:
            before = (given.pos, taken.pos)
            hint = _check(_lib.ZSTD_decompressStream(self._context, ctypes.byref(taken), ctypes.byref(given)))
            if (given.pos, taken.pos) == before:
                break
        # A record ends where a flush ended a block: the decoder then asks for exactly the
        # next block's 3-byte header, holding no input of it.
        if given.pos != given.size or taken.pos != expected or hint != BLOCK_HEADER:
            raise ValueError("zstd: record boundary")
        return output.raw[:expected]

    def __del__(self):
        if getattr(self, "_context", None):
            _lib.ZSTD_freeDCtx(self._context)
            self._context = None
