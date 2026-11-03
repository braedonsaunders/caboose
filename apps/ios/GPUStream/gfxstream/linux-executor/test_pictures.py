"""Content measures and PPM output of captured pictures (surfaces.content, write_picture)."""
import ctypes
import os
import random
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import native  # noqa: E402
import surfaces  # noqa: E402


def picture(width, height, texel, pitch_pad=16, vk_format=44):
    pitch = width * 4 + pitch_pad
    data = bytearray(pitch * height)
    for y in range(height):
        for x in range(width):
            data[y * pitch + x * 4:y * pitch + x * 4 + 4] = texel(x, y).to_bytes(4, 'little')
    buffer = (ctypes.c_char * len(data)).from_buffer(data)
    return native.CapturePixels(ctypes.addressof(buffer), pitch, width, height, vk_format), buffer


class Pictures(unittest.TestCase):
    def test_a_rendered_window_repeats_and_has_a_few_colours(self):
        def window(x, y):
            if y < 10: return 0xff204080
            return 0xff000000 if (x // 3 + y // 5) % 7 == 0 else 0xffe8f0ff
        pixels, _ = picture(200, 60, window)
        repeat, colours = surfaces.content(pixels)
        self.assertGreater(repeat, 0.5)
        self.assertLess(repeat, 0.999)
        self.assertEqual(colours, 3)

    def test_noise_repeats_in_almost_no_texels(self):
        generator = random.Random(7)
        pixels, _ = picture(200, 60, lambda x, y: generator.getrandbits(32))
        repeat, colours = surfaces.content(pixels)
        self.assertLess(repeat, 0.05)
        self.assertEqual(colours, 64)

    def test_a_picture_nothing_drew_into_is_one_colour(self):
        pixels, _ = picture(64, 16, lambda x, y: 0)
        self.assertEqual(surfaces.content(pixels), (1.0, 1))

    def test_other_formats_have_no_measure(self):
        pixels, _ = picture(8, 8, lambda x, y: 0, vk_format=97)
        self.assertIsNone(surfaces.content(pixels))

    def test_a_ppm_holds_the_rows_without_padding_in_rgb(self):
        pixels, _ = picture(2, 1, lambda x, y: 0xff112233 if x == 0 else 0xff445566)
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, 'window.ppm')
            surfaces.write_picture(path, pixels)
            with open(path, 'rb') as ppm:
                self.assertEqual(ppm.read(), b'P6\n2 1\n255\n' + bytes([0x11, 0x22, 0x33, 0x44, 0x55, 0x66]))


if __name__ == '__main__':
    unittest.main()
