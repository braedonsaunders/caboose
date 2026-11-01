# Caboose input

The input system takes what the phone sends in the display protocol (`pointer`, `touch`,
`pencil`, `key`, `text`; [display.md](display.md#messages)) and delivers it to
applications the way a Linux input stack does: as Wayland seat events, and through
Xwayland as core X and XInput 2 events. It is independent of the pictures: input is
never turned into a change of what the phone shows, and a picture never stands in for
an application's own response to input.

| Piece | What |
| --- | --- |
| `guest/display/compositor/src/input.rs` | The seat: pointer, touch, keys, text, pointer constraints |
| `guest/display/compositor/src/input/scroll.rs` | Scrolling as `wl_pointer` axis events |
| `guest/display/compositor/src/input/xwayland.rs` | The X11 finger scroll distance, set on Xwayland |
| `guest/display/compositor/src/pencil.rs` | Apple Pencil as the seat's tablet pen |
| `guest/xwayland/touchpad-scroll.patch` | Xwayland's touchpad device for finger scrolling ([guest/xwayland](../guest/xwayland/README.md)) |

## Scrolling

A `pointer` message's `scroll` is either precise or wheel clicks. Precise scrolling is a
finger: a pan on the phone's screen or trackpad, its coasting, in the window's pixels
(display pixels), one message per display refresh while the content moves. Wheel
scrolling is clicks of a mouse wheel, `dy` 1 for one click down.

### Wayland

A scroll sample is one `wl_pointer.frame`, with the motion of its `pointer` message.

| Input | `axis_source` | `axis` value | `axis_value120` |
| --- | --- | --- | --- |
| Precise `dx`, `dy` | `finger` | `dx / s`, `dy / s` logical pixels at the window's display scale `s` | none |
| Wheel clicks `n` | `wheel` | `15 n` logical pixels | `120 n` |

A finger sequence ends with `axis_stop` on both axes 50 ms after its last sample, where
clients finish the gesture and start their own kinetic scrolling. An axis that did not
move is not sent.

### X11

Xwayland receives the same events scaled to X pixels, which are display pixels
(Xwayland has the primary display's scale as its client scale). Caboose's Xwayland
delivers them as XInput 2.1 smooth scrolling ([guest/xwayland](../guest/xwayland/README.md)):

- Finger frames, with their motion, come from the slave pointer `xwayland-touchpad`,
  of X input type `TOUCHPAD`. Its scroll valuators (3 vertical, 2 horizontal) move by
  the axis value in X pixels, and `axis_stop` moves them by zero. One scroll increment
  is the device's `Xwayland Scroll Pixel Distance`, which caboose-display sets to
  `120 * s` for the X11 scale `s` when Xwayland starts and whenever the scale changes.
- Wheel frames come from Xwayland's pointer device, one increment per click.
- The X server emulates a core button 4 to 7 click per increment (from both devices) for
  clients without XInput 2.1.
- XI2 clients count a scroll valuator's change between two events of one device and
  forget its position when the core pointer switches devices or enters a window. Each
  finger sequence, and a scroll event that follows another device's, starts with an
  event that moves the scroll valuators by zero, so no sample is lost.

What applications do with it:

| Client | Finger scrolling | Wheel |
| --- | --- | --- |
| Chromium, Electron, CEF (Steam) | A touchpad scroll of 120 of its pixels per increment: a pan of `N` window pixels scrolls `N / s` CSS pixels, applied as it comes with no animation; `axis_stop` ends the gesture | An animated step per click |
| GTK 3 | Smooth scroll events of `N / (120 s)` steps, each step `min(page^(2/3), page / 2)` pixels of the scrolled view (`page` its height in X pixels), and kinetic scrolling from `axis_stop`. GTK 3 classes the device a mouse, as it recognises touchpads only by a libinput driver property | A step per click |
| Core X clients (xterm) | Buttons 4 and 5, one click per `120 s` X pixels | A click per click |

For Chromium on X11 at scale 2, `scripts/check-finger-scroll.py` in guest/display
measures a pan of ten 40-pixel samples 16 ms apart scrolling 200 CSS pixels, no longer
than the samples, and a wheel click 118 to 120 CSS pixels animated over 150 to 175 ms. GTK 3 at
the same scale, with a 1902-pixel view, moves 256 pixels for that pan before its kinetic
scrolling.

The phone's direct-content pans (a finger on a window's picture, as opposed to its
trackpad) are sent as one twelfth of the finger's window pixels
(`apps/ios` `DirectScrollCalibration`), so Chromium on X11 scrolls a twelfth of the
finger's distance for them.

## Checks

`cargo test -p caboose-display input::` in guest/display covers the scroll units and
the X11 scroll distance. `scripts/check-finger-scroll.py` in guest/display checks finger
and wheel scrolling end to end in Chromium on X11 through the computer's Xwayland
([guest/display](../guest/display/README.md)).
