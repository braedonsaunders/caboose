"""Number visible controls on a PNG; coordinates in the legend remain seat coordinates."""
import math

DIGITS = ('111101101101111', '010110010010111', '111001111100111',
          '111001111001111', '101101111001001', '111100111001111',
          '111100111101111', '111001001001001', '111101111101111', '111101111001111')


def annotate(path, rect, elements, window=None):
    import gi
    gi.require_version('GdkPixbuf', '2.0')
    from gi.repository import GdkPixbuf, GLib
    source = GdkPixbuf.Pixbuf.new_from_file(path)
    width, height = source.get_width(), source.get_height()
    channels, stride = source.get_n_channels(), source.get_rowstride()
    pixels = bytearray(source.get_pixels())
    ox, oy, rw, rh = rect
    sx, sy = width / rw, height / rh
    legend = []

    def pixel(x, y, color):
        if 0 <= x < width and 0 <= y < height:
            at = y * stride + x * channels
            pixels[at:at + channels] = bytes(color[:channels])

    for element in elements[:200]:
        if window is not None and not element['id'].startswith(f'{window:x}-'):
            continue
        b = element['bounds']
        x = max(0, math.floor((b['x'] - ox) * sx))
        y = max(0, math.floor((b['y'] - oy) * sy))
        right = min(width - 1, math.ceil((b['x'] + b['width'] - ox) * sx) - 1)
        bottom = min(height - 1, math.ceil((b['y'] + b['height'] - oy) * sy) - 1)
        if right < x or bottom < y:
            continue
        mark = len(legend) + 1
        color = (255, 210, 0, 255)
        for px in range(x, right + 1):
            pixel(px, y, color)
            pixel(px, bottom, color)
        for py in range(y, bottom + 1):
            pixel(x, py, color)
            pixel(right, py, color)
        label = str(mark)
        bx = min(x, max(0, width - len(label) * 8 - 2))
        by = min(y, max(0, height - 12))
        for py in range(by, by + 12):
            for px in range(bx, bx + len(label) * 8 + 2):
                pixel(px, py, color)
        for n, digit in enumerate(label):
            for i, bit in enumerate(DIGITS[int(digit)]):
                if bit == '1':
                    for dx in range(2):
                        for dy in range(2):
                            pixel(bx + 1 + n * 8 + (i % 3) * 2 + dx, by + 1 + (i // 3) * 2 + dy, (0, 0, 0, 255))
        legend.append({key: element[key] for key in ('id', 'role', 'name', 'bounds')})
        legend[-1].update(mark=mark, center=[b['x'] + b['width'] / 2, b['y'] + b['height'] / 2])
    output = GdkPixbuf.Pixbuf.new_from_bytes(GLib.Bytes.new(bytes(pixels)), source.get_colorspace(),
        source.get_has_alpha(), 8, width, height, stride)
    output.savev(path, 'png', [], [])
    return legend
