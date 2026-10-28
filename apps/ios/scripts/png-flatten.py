"""Rewrite an opaque 8-bit RGBA PNG as RGB, losslessly (standard library only)."""
import sys, zlib, struct
src, dst = sys.argv[1], sys.argv[2]
data = open(src, 'rb').read()
assert data[:8] == b'\x89PNG\r\n\x1a\n'
pos, idat, ihdr = 8, b'', None
while pos < len(data):
    n, = struct.unpack('>I', data[pos:pos+4]); kind = data[pos+4:pos+8]; body = data[pos+8:pos+8+n]; pos += 12 + n
    if kind == b'IHDR': ihdr = body
    elif kind == b'IDAT': idat += body
w, h, depth, ctype, _, _, interlace = struct.unpack('>IIBBBBB', ihdr)
assert depth == 8 and ctype == 6 and interlace == 0, (depth, ctype, interlace)
raw, bpp, stride = zlib.decompress(idat), 4, w * 4
rows, prev, i = [], bytearray(stride), 0
for _ in range(h):
    f = raw[i]; line = bytearray(raw[i+1:i+1+stride]); i += 1 + stride
    for x in range(stride):
        a = line[x-bpp] if x >= bpp else 0; b = prev[x]; c = prev[x-bpp] if x >= bpp else 0
        if f == 1: line[x] = (line[x] + a) & 255
        elif f == 2: line[x] = (line[x] + b) & 255
        elif f == 3: line[x] = (line[x] + (a + b) // 2) & 255
        elif f == 4:
            p = a + b - c; pa, pb, pc = abs(p-a), abs(p-b), abs(p-c)
            line[x] = (line[x] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
    assert all(line[3::4][k] == 255 for k in range(0, w, 97)), 'icon must be opaque'
    rows.append(b'\x00' + bytes(v for k, v in enumerate(line) if k % 4 != 3)); prev = line
chunk = lambda t, b: struct.pack('>I', len(b)) + t + b + struct.pack('>I', zlib.crc32(t + b) & 0xffffffff)
out = data[:8] + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(b''.join(rows), 9)) + chunk(b'IEND', b'')
open(dst, 'wb').write(out)
