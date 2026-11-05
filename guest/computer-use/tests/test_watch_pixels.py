"""check/watch_pixels.py: black, noise and cleared frames fail; a desktop passes; frames that
do not change fail --moving."""
import importlib.util
import os
import random
import struct
import subprocess
import sys
import tempfile
import unittest
import zlib

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(HERE, 'check', 'watch_pixels.py')
spec = importlib.util.spec_from_file_location('watch_pixels', SCRIPT)
watch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(watch)


def png(width, height, pixel, filter_type=0):
    rows = b''.join(bytes([filter_type]) + bytes(c for x in range(width) for c in pixel(x, y)) for y in range(height))
    chunk = lambda kind, body: struct.pack('>I', len(body)) + kind + body + struct.pack('>I', zlib.crc32(kind + body) & 0xffffffff)
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(rows)) + chunk(b'IEND', b'')


def desktop(offset=0):
    # A dark background, a light window with a title bar and some text-like marks.
    def pixel(x, y):
        if 40 + offset <= x < 200 + offset and 30 <= y < 150:
            if y < 45:
                return (60, 60, 70)
            if 60 <= y < 140 and (x // 3) % 4 == 0 and (y // 6) % 2 == 0:
                return (20, 20, 20)
            return (235, 235, 240)
        return (30, 50, 90)
    return png(256, 192, pixel)


class Scores(unittest.TestCase):
    def kind(self, data):
        return watch.score(watch.decode_png(data)[2])['kind']

    def test_black_noise_and_cleared_frames_are_not_pictures(self):
        rng = random.Random(1)
        self.assertEqual(self.kind(png(128, 96, lambda x, y: (0, 0, 2))), 'black')
        self.assertEqual(self.kind(png(128, 96, lambda x, y: (rng.randrange(256),) * 3)), 'noise')
        self.assertEqual(self.kind(png(128, 96, lambda x, y: (128, 128, 128))), 'uniform')

    def test_a_desktop_is_a_picture(self):
        self.assertEqual(self.kind(desktop()), 'picture')

    def test_sub_and_up_filtered_rows_decode_like_unfiltered_ones(self):
        width, height = 64, 32
        pixels = [[(x * 4 % 256, y * 8 % 256, (x + y) % 256) for x in range(width)] for y in range(height)]
        raw = [bytes(c for p in row for c in p) for row in pixels]

        def encoded(kind):
            out, previous = b'', bytes(width * 3)
            for line in raw:
                if kind == 1:
                    body = bytes((line[i] - (line[i - 3] if i >= 3 else 0)) & 255 for i in range(len(line)))
                elif kind == 2:
                    body = bytes((line[i] - previous[i]) & 255 for i in range(len(line)))
                else:
                    body = line
                out += bytes([kind]) + body
                previous = line
            chunk = lambda k, b: struct.pack('>I', len(b)) + k + b + struct.pack('>I', zlib.crc32(k + b) & 0xffffffff)
            return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(out)) + chunk(b'IEND', b'')
        plain = watch.decode_png(encoded(0))[2]
        self.assertEqual(watch.decode_png(encoded(1))[2], plain)
        self.assertEqual(watch.decode_png(encoded(2))[2], plain)


class Command(unittest.TestCase):
    def run_on(self, frames, *options):
        directory = tempfile.mkdtemp()
        paths = []
        for index, data in enumerate(frames):
            paths.append(os.path.join(directory, f'{index}.png'))
            with open(paths[-1], 'wb') as f:
                f.write(data)
        return subprocess.run([sys.executable, SCRIPT, *options, *paths], capture_output=True, text=True).returncode

    def test_moving_desktop_passes_and_still_or_black_fails(self):
        self.assertEqual(self.run_on([desktop(0), desktop(12), desktop(24)], '--moving'), 0)
        self.assertEqual(self.run_on([desktop(0), desktop(0)], '--moving'), 1)
        self.assertEqual(self.run_on([desktop(0), png(256, 192, lambda x, y: (0, 0, 0))]), 1)
        self.assertEqual(self.run_on([desktop(0)], '--region', '0,0,128,96'), 0)
        self.assertEqual(self.run_on([b'not a png']), 2)


if __name__ == '__main__':
    unittest.main()
