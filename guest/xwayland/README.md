# Caboose's Xwayland

The computer's Xwayland is Debian's, built with the patches here: DRI3 on the render
node, and finger scrolling from a touchpad device.

| File | What |
| --- | --- |
| `dri3-render-node.patch` | Without glamor, DRI3 opens the render node named by `CABOOSE_XWAYLAND_RENDER_NODE` |
| `touchpad-scroll.patch` | Scrolling with `axis_source` finger comes from a touchpad device as XI2.1 smooth scrolling |
| `build.sh` | Builds Debian's `xwayland` package with the patches, versioned `+caboose1` |

## DRI3 on the render node

A computer's only DRM device is the `vgem` render node
([docs/gpu-buffers.md](../../docs/gpu-buffers.md)), which has no GL driver, so Xwayland runs without glamor and, unpatched, without DRI3.
X11 clients then have no way to open the render node: Chromium on X11 takes its GBM
device from DRI3, and without one it cannot import the NV12 buffers the VA-API driver
decodes into, so video in Chromium, Electron and Steam's web views would be decoded and
uploaded on the computer instead of on the phone ([docs/gpu-media.md](../../docs/gpu-media.md)).

The patched server answers DRI3 `Open` with a descriptor of the node and advertises
nothing else: `PixmapFromBuffers` fails, so buffers are never imported as pixmaps and
presentation is unchanged. caboose-display sets the variable for its Xwayland on the seat
that renders on the phone's GPU, when the computer has a vgem render node. Mesa's GLX and
EGL clients then try DRI3 first, find no GL driver for `vgem` and fall back to their
software path as before (they print `failed to load driver: vgem`).

## Finger scrolling

Debian's Xwayland ignores `wl_pointer.axis_source` and turns every axis event into
scroll valuator motion of its pointer device, a tenth of the value per scroll increment.
X11 clients read that as a mouse wheel: Chromium animates each event as a wheel step
of 120 pixels per increment, so a pan of a few pixels scrolls hundreds.

With the patch, a frame whose axis events have source finger (and no discrete steps),
and the frame's motion, come from a slave device `xwayland-touchpad:SEAT` of X input
type `TOUCHPAD`. Its scroll valuators (3 vertical, 2 horizontal) move by the axis value
in X pixels; `axis_stop` is a move of zero, which ends the sequence (GTK starts its
kinetic scrolling there, Chromium ends the gesture). One scroll increment is the
device's `Xwayland Scroll Pixel Distance` property, one CARD32, 120 until a client sets
it; caboose-display sets it to 120 times the X11 scale ([docs/input.md](../../docs/input.md)).
The X server emulates a core button 4 to 7 click per increment for clients without
XI2.1.

XI2 clients take the difference between a scroll valuator's position in consecutive
events of one device, and forget the position when the core pointer switches devices or
enters a window. Each finger sequence, and any scroll event that follows another
device's, therefore starts with an event that moves the scroll valuators by nothing, so
no delta is lost. Wheel and `axis_value120` scrolling stays on the pointer device as in
Debian's build.

## Building

```sh
guest/xwayland/build.sh OUTPUT_DIRECTORY
```

in a Debian 13 environment with `deb-src` entries, `apt-get build-dep xwayland` and
`dpkg-dev`; the container image builds it in its `xwayland` stage. The patches are against
the release's Xwayland (24.1); a release whose source they do not apply to fails the build.

## Checking

`guest/display/scripts/check-finger-scroll.py` pans Chromium on X11 through this
Xwayland and measures how far the page scrolls ([guest/display](../display/README.md)).

For DRI3, on a computer, or in a container of the image with `/dev/dri` passed through, with
caboose-display running as the GPU seat:

```sh
xdpyinfo | grep DRI3
```

lists the extension, and Chromium started with the seat's flags logs no
`SharedImageBackingFactory` errors while it plays a video through the VA-API driver.
