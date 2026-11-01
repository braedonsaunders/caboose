#!/usr/bin/env python3
"""A GTK 3 window that draws what GTK applications draw: themed widgets, text in several
fonts, an entry, a scrolled text view, icons, and a drawing area with gradients, dashes,
arcs, curves and an image. It scrolls its text view a step every 30 ms (for SCROLL_FOR seconds,
when set), then quits."""
import math
import os
import sys

import gi
gi.require_version("Gtk", "3.0")
from gi.repository import GLib, Gtk  # noqa: E402

import cairo  # noqa: E402

SECONDS = float(sys.argv[1]) if len(sys.argv) > 1 else 3.0


def draw(area, cr):
    w, h = area.get_allocated_width(), area.get_allocated_height()
    g = cairo.LinearGradient(0, 0, w, h)
    g.add_color_stop_rgba(0, 0.95, 0.55, 0.15, 1)
    g.add_color_stop_rgba(1, 0.15, 0.35, 0.85, 1)
    cr.set_source(g)
    cr.rectangle(0, 0, w, h)
    cr.fill()
    r = cairo.RadialGradient(w * 0.7, h * 0.4, 2, w * 0.7, h * 0.4, h * 0.45)
    r.add_color_stop_rgba(0, 1, 1, 1, 0.9)
    r.add_color_stop_rgba(1, 1, 1, 1, 0)
    cr.set_source(r)
    cr.arc(w * 0.7, h * 0.4, h * 0.45, 0, 2 * math.pi)
    cr.fill()
    cr.set_source_rgba(0.1, 0.1, 0.1, 0.85)
    cr.set_line_width(3)
    cr.set_dash([8, 4], 2)
    cr.move_to(10, h - 10)
    cr.curve_to(w * 0.3, 0, w * 0.6, h, w - 10, 10)
    cr.stroke()
    cr.set_dash([])
    cr.save()
    cr.translate(w * 0.25, h * 0.5)
    cr.rotate(0.4)
    cr.scale(1.5, 0.8)
    cr.set_line_join(cairo.LINE_JOIN_ROUND)
    cr.rectangle(-20, -20, 40, 40)
    cr.set_source_rgb(0.9, 0.9, 0.2)
    cr.fill_preserve()
    cr.set_source_rgb(0, 0, 0)
    cr.stroke()
    cr.restore()
    cr.save()
    cr.arc(w * 0.5, h * 0.5, 30, 0, 2 * math.pi)
    cr.clip()
    img = cairo.ImageSurface(cairo.FORMAT_ARGB32, 16, 16)
    data = img.get_data()
    for y in range(16):
        for x in range(16):
            o = (y * img.get_stride()) + x * 4
            on = (x // 4 + y // 4) % 2
            data[o:o + 4] = bytes([200 * on, 80, 255 - 200 * on, 255])
    img.mark_dirty()
    p = cairo.SurfacePattern(img)
    p.set_extend(cairo.EXTEND_REPEAT)
    p.set_filter(cairo.FILTER_NEAREST)
    cr.set_source(p)
    cr.paint_with_alpha(0.8)
    cr.restore()
    cr.select_font_face("DejaVu Serif", cairo.FONT_SLANT_ITALIC, cairo.FONT_WEIGHT_BOLD)
    cr.set_font_size(22)
    cr.move_to(12, 30)
    cr.set_source_rgb(1, 1, 1)
    cr.show_text("cairo, recorded")
    return False


win = Gtk.Window(title="draw check")
win.set_default_size(420, 640)
box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6, margin=8)
win.add(box)
title = Gtk.Label()
title.set_markup("<big><b>The caboose</b></big> rides at the <i>end</i> of the <tt>train</tt>")
box.pack_start(title, False, False, 0)
row = Gtk.Box(spacing=6)
row.pack_start(Gtk.Button.new_from_icon_name("document-open", Gtk.IconSize.BUTTON), False, False, 0)
row.pack_start(Gtk.Button(label="Couple"), False, False, 0)
check = Gtk.CheckButton(label="Brakes set")
check.set_active(True)
row.pack_start(check, False, False, 0)
row.pack_start(Gtk.Switch(active=True), False, False, 0)
box.pack_start(row, False, False, 0)
entry = Gtk.Entry(text="Milepost 214, eastbound")
box.pack_start(entry, False, False, 0)
progress = Gtk.ProgressBar(fraction=0.62, show_text=True)
box.pack_start(progress, False, False, 0)
area = Gtk.DrawingArea()
area.set_size_request(-1, 180)
area.connect("draw", draw)
box.pack_start(area, False, False, 0)
scroller = Gtk.ScrolledWindow()
view = Gtk.TextView()
view.get_buffer().set_text("\n".join(
    f"{i:3}  Car {i}: {'boxcar' if i % 3 else 'tank car'}, {(i * 37) % 90 + 10} tons, seal {(i * 7919) % 100000:05}"
    for i in range(300)))
scroller.add(view)
box.pack_start(scroller, True, True, 0)
win.connect("destroy", Gtk.main_quit)
win.show_all()

ticks = [0]


SCROLL_FOR = float(os.environ.get("SCROLL_FOR", "inf"))


def tick():
    if ticks[0] * 0.03 > SCROLL_FOR:
        return False
    ticks[0] += 1
    adj = scroller.get_vadjustment()
    adj.set_value(adj.get_value() + 7)
    progress.set_fraction((ticks[0] % 100) / 100)
    return True


GLib.timeout_add(30, tick)
GLib.timeout_add(int(SECONDS * 1000), Gtk.main_quit)
Gtk.main()
