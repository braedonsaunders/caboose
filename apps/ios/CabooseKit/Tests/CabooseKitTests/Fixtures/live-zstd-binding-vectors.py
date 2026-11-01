# Generates live-zstd-binding-vectors.json: CGLV DATA envelopes and their algorithm 2 records,
# one zstd stream (level 3, window log 23) flushed after each envelope. Needs libzstd.

import ctypes, struct, json, sys
z = ctypes.CDLL("/opt/homebrew/lib/libzstd.dylib")
z.ZSTD_createCCtx.restype = ctypes.c_void_p
class InB(ctypes.Structure): _fields_=[("src",ctypes.c_void_p),("size",ctypes.c_size_t),("pos",ctypes.c_size_t)]
class OutB(ctypes.Structure): _fields_=[("dst",ctypes.c_void_p),("size",ctypes.c_size_t),("pos",ctypes.c_size_t)]
z.ZSTD_compressStream2.restype = ctypes.c_size_t
z.ZSTD_compressStream2.argtypes=[ctypes.c_void_p, ctypes.POINTER(OutB), ctypes.POINTER(InB), ctypes.c_int]
z.ZSTD_CCtx_setParameter.argtypes=[ctypes.c_void_p, ctypes.c_int, ctypes.c_int]
cctx = z.ZSTD_createCCtx()
z.ZSTD_CCtx_setParameter(cctx, 100, 3)   # compressionLevel
z.ZSTD_CCtx_setParameter(cctx, 101, 23)  # windowLog
executor = bytes([1]) * 16; gen = 7
def env(kind, seq, process, stream, payload):
    return b"CGLV"+struct.pack("<HHII",1,kind,len(payload),0)+executor+struct.pack("<QQQQ",gen,process,stream,seq)+payload
out=[]
payloads=[bytes([i % 7]) * 300 for i in range(3)] + [b"hello world, hello world, " * 20]
for i,p in enumerate(payloads):
    e = env(7, 5+i, 1, 1, p)
    src = ctypes.create_string_buffer(e, len(e)); dst = ctypes.create_string_buffer(len(e)*2+64)
    inb = InB(ctypes.cast(src,ctypes.c_void_p), len(e), 0); outb = OutB(ctypes.cast(dst,ctypes.c_void_p), len(dst), 0)
    r = z.ZSTD_compressStream2(cctx, ctypes.byref(outb), ctypes.byref(inb), 1)  # ZSTD_e_flush
    assert r == 0 and inb.pos == len(e)
    body = dst.raw[:outb.pos]
    rec = b"CGLZ"+struct.pack("<HHII",1,2,len(e),len(body))+body
    out.append({"envelope": e.hex(), "record": rec.hex()})
json.dump(out, sys.stdout, indent=1)
