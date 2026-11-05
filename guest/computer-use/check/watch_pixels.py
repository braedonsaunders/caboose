#!/usr/bin/python3
"""Whether pictures of a seat show real pixels: neither black nor noise, and, over several
frames, moving.

usage: watch_pixels.py [--region X,Y,W,H] [--moving] FRAME.png...

Scores each frame (an 8-bit RGB or RGBA PNG, as a phone screenshot or a seat picture is) on a
grid of samples, by luma:

  black   the share of samples darker than 12/255;
  flat    the share of horizontally adjacent samples within 2 of each other (a desktop's
          windows and backgrounds are mostly flat);
  edges   the share differing by more than 40 (random noise is mostly edges).

A frame is `black` when black > 0.97, `noise` when edges > 0.45 and flat < 0.2, `uniform`
when nearly every sample is one colour (a cleared surface of any colour), else `picture`.
--moving also requires each frame to differ from the one before it (more than 0.2% of the
samples changed by more than 8). --region scores only that part of each frame (the Watch
view, without the phone's own bars). Prints one JSON line per frame and a verdict line; exits
0 when every frame is a picture (and moving when asked), 1 when not, 2 on bad input.
Standard library only.
"""
import argparse
import json
import struct
import sys
import zlib

STEP = 4  # every 4th pixel in each direction


def decode_png(data):
    """(width, height, rows of luma bytes) of an 8-bit RGB/RGBA/grey PNG, sampled every STEP pixels."""
    if data[:8] != b'\x89PNG\r\n\x1a\n':
        raise ValueError('not a PNG')
    pos, idat, header = 8, [], None
    while pos < len(data):
        length, kind = struct.unpack('>I4s', data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + length]
        if kind == b'IHDR':
            header = struct.unpack('>IIBBBBB', body)
        elif kind == b'IDAT':
            idat.append(body)
        elif kind == b'IEND':
            break
        pos += 12 + length
    if header is None:
        raise ValueError('no IHDR')
    width, height, depth, colour, _, _, interlace = header
    channels = {0: 1, 2: 3, 4: 2, 6: 4}.get(colour)
    if depth != 8 or channels is None or interlace:
        raise ValueError(f'unsupported PNG (depth {depth}, colour {colour}, interlace {interlace})')
    raw = zlib.decompress(b''.join(idat))
    stride = width * channels
    previous = bytearray(stride)
    rows = []
    for y in range(height):
        start = y * (stride + 1)
        kind, line = raw[start], bytearray(raw[start + 1:start + 1 + stride])
        for i in range(stride):
            left = line[i - channels] if i >= channels else 0
            up = previous[i]
            if kind == 1:
                line[i] = (line[i] + left) & 255
            elif kind == 2:
                line[i] = (line[i] + up) & 255
            elif kind == 3:
                line[i] = (line[i] + (left + up) // 2) & 255
            elif kind == 4:
                corner = previous[i - channels] if i >= channels else 0
                p = left + up - corner
                pa, pb, pc = abs(p - left), abs(p - up), abs(p - corner)
                line[i] = (line[i] + (left if pa <= pb and pa <= pc else up if pb <= pc else corner)) & 255
        previous = line
        if y % STEP == 0:
            if channels >= 3:
                rows.append(bytes((line[x] * 299 + line[x + 1] * 587 + line[x + 2] * 114) // 1000
                                  for x in range(0, stride, channels * STEP)))
            else:
                rows.append(bytes(line[x] for x in range(0, stride, channels * STEP)))
    return width, height, rows


def crop(rows, region):
    if not region:
        return rows
    x, y, w, h = (v // STEP for v in region)
    return [row[x:x + max(1, w)] for row in rows[y:y + max(1, h)]]


def score(rows):
    samples = sum(len(row) for row in rows)
    pairs = sum(max(0, len(row) - 1) for row in rows)
    if not samples or not pairs:
        raise ValueError('empty picture')
    black = sum(1 for row in rows for v in row if v < 12) / samples
    flat = edges = 0
    histogram = [0] * 32
    for row in rows:
        for a, b in zip(row, row[1:]):
            d = abs(a - b)
            flat += d <= 2
            edges += d > 40
        for v in row:
            histogram[v >> 3] += 1
    flat, edges = flat / pairs, edges / pairs
    dominant = max(histogram) / samples
    kind = 'black' if black > 0.97 else 'noise' if edges > 0.45 and flat < 0.2 else 'uniform' if dominant > 0.995 else 'picture'
    return {'kind': kind, 'black': round(black, 4), 'flat': round(flat, 4), 'edges': round(edges, 4), 'dominant': round(dominant, 4)}


def changed(before, after):
    """The share of samples that changed by more than 8 between two frames of one size."""
    total = moved = 0
    for a, b in zip(before, after):
        for x, y in zip(a, b):
            total += 1
            moved += abs(x - y) > 8
    return moved / total if total else 0.0


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    parser.add_argument('frames', nargs='+')
    parser.add_argument('--region', type=lambda s: tuple(int(v) for v in s.split(',')))
    parser.add_argument('--moving', action='store_true')
    args = parser.parse_args(argv)
    if args.region is not None and len(args.region) != 4:
        parser.error('--region is X,Y,W,H')
    ok, previous, motion = True, None, []
    for path in args.frames:
        try:
            with open(path, 'rb') as f:
                rows = crop(decode_png(f.read())[2], args.region)
            result = score(rows)
        except (OSError, ValueError, zlib.error) as error:
            print(json.dumps({'frame': path, 'error': str(error)}))
            return 2
        if previous is not None and len(previous) == len(rows):
            result['changed'] = round(changed(previous, rows), 4)
            motion.append(result['changed'])
        previous = rows
        ok &= result['kind'] == 'picture'
        print(json.dumps({'frame': path, **result}))
    moving = bool(motion) and all(m > 0.002 for m in motion)
    if args.moving:
        ok &= moving
    print(json.dumps({'verdict': 'pass' if ok else 'fail', 'frames': len(args.frames), **({'moving': moving} if args.moving else {})}))
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
