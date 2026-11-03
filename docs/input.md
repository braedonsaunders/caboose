# Caboose input

The input system takes what the phone sends in the display protocol (`pointer`, `touch`,
`pencil`, `pinch`, `swipe`, `hold`, `key`, `text`; [display.md](display.md#messages)) and delivers it to
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

## Keyboard

Hardware keys carry their USB HID keyboard-page usage as well as a keysym. The compositor
maps recognized usages to evdev positions and uses the keysym when no position is supplied
or recognized. Synthetic keys use the keysym and the seat keymap.

## Gestures

A `pinch`, `swipe` or `hold` from the phone is delivered through
`zwp_pointer_gestures_v1` v3 to the surface under the gesture's centre when it began:
pinch with its scale since `begin` and its rotation since the previous sample, swipe
with the centre's movement, and hold with its finger count. The target does not change
while the gesture runs. Through Xwayland the same gestures arrive as XInput 2.4
gesture events, so an X11 application that understands pinch zooms itself. No
application is given a keyboard shortcut or any other substitute, and no application
is treated specially.

## Scrolling

A `pointer` message's `scroll` is either precise or wheel clicks. Precise scrolling is a
finger: a pan on the phone's screen or trackpad, in the window's pixels (display pixels),
one message per display refresh while the finger moves; the last carries the finger's
velocity as it lifted (`lift`). Wheel scrolling is clicks of a mouse wheel, `dy` 1 for
one click down.

### Wayland

A scroll sample is one `wl_pointer.frame`, with the motion of its `pointer` message.

| Input | `axis_source` | `axis` value | `axis_value120` |
| --- | --- | --- | --- |
| Precise `dx`, `dy` | `finger` | `dx / s`, `dy / s` logical pixels at the window's display scale `s` | none |
| Wheel clicks `n` | `wheel` | `15 n` logical pixels | `120 n` |

A finger sequence ends with `axis_stop` on both axes when it stops: after kinetic
scrolling (below), at once for a lift too slow to coast, or 50 ms after the last sample of
a client that sends no `lift`. An axis that did not move is not sent.

### Kinetic scrolling

Content keeps moving after the finger lifts, as a touchpad driver's coasting does, and it is
the input system that moves it: the phone sends the finger and nothing after it. A
`scroll.lift` of `[vx, vy]` window pixels per second at least 80 fast starts coasting at
that velocity (at most 30000): finger axis events at the window's display refresh, each
the distance covered since the last, the velocity slowing by 0.2 % a millisecond (a
UIScrollView's normal deceleration) until it is under 20 pixels per second, then
`axis_stop`. A lift at 2000 pixels per second coasts 989 pixels in 2.3 seconds, at any
refresh rate. Wayland and X11 clients see one finger sequence, so an application's own
kinetic scrolling, started at `axis_stop`, starts from the coast's last speed and adds
nothing visible.

A `scroll.hold` (a finger touched down on the phone), any other scroll, a button and a
touch down stop coasting at once with `axis_stop`. The phone sends `hold` only while the
computer may still be coasting a scroll it lifted.

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
trackpad) are sent as the finger's distance in window pixels, so content moves with the
finger.

## Checks

`cargo test -p caboose-display input::` in guest/display covers the scroll units,
kinetic scrolling's distance and stop, and the X11 scroll distance; `swift test` in
apps/ios/CabooseKit covers the phone's samples and lift (`ScrollPhysicsTests`). `scripts/check-finger-scroll.py` in guest/display checks finger
and wheel scrolling end to end in Chromium on X11 through the computer's Xwayland
([guest/display](../guest/display/README.md)).
