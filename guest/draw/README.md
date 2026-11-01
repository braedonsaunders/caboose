# Caboose Draw (`guest/draw`)

Records what applications draw on the CPU as Caboose draw lists: paths, strokes, gradients,
images, glyph outlines, clips and offscreen surfaces. The device can then draw the same
picture with its own GPU, at its own density. The format is specified in
[docs/draw.md](../../docs/draw.md).

| Path | What |
| --- | --- |
| `src/cdl.h` | The draw-list writer and the constants every reader shares (no dependencies) |
| `src/cairo_recorder.c` | `libcaboose-draw-cairo.so`, the cairo recorder, loaded with `LD_PRELOAD` |
| `src/cdl_replay.c` | `caboose-draw-replay`, which draws a capture again with cairo and checks it against what the application drew |
| `tests/check.sh` | Records GTK 3 and LibreOffice Writer under a headless Weston and replays them |
| `tests/gtk3_scene.py` | The GTK 3 window that check uses: widgets, text, icons, gradients, dashes, clips, images |

## The cairo recorder

`libcaboose-draw-cairo.so` interposes the cairo calls applications and toolkits make through
the dynamic linker: `cairo_fill`, `cairo_stroke`, `cairo_paint` and `cairo_mask` (with their
`_preserve`, `_with_alpha` and `_surface` forms), `cairo_show_glyphs`, `cairo_show_text_glyphs`,
`cairo_show_text`, the clip, save/restore and group calls, surface creation, and direct pixel
access. For each drawing call it reads the state through cairo's public getters (path, matrix,
operator, source pattern, stroke style, scaled font, current group target), writes the op, and
calls cairo on. Calls cairo makes internally do not reach it, so each operation is recorded once.

- **Clips** are tracked per `cairo_t` from `cairo_clip`, `cairo_save`/`cairo_restore` and the
  group calls, since cairo cannot hand back a clip that is not rectangles.
- **Surfaces.** A surface created clear (`cairo_image_surface_create`, `create_similar`, a group)
  is *recorded*: its content is its ops, and the device holds it as an offscreen. A surface
  written directly (`cairo_image_surface_get_data`, `cairo_surface_mark_dirty`) or created over
  existing memory is *pixels*: used as a source, its pixels are sent once as a content-addressed
  image. A wl_shm buffer is the exception: toolkits allocate buffers from fresh, zeroed shared
  memory, so a buffer is recorded like a surface created clear, and a toolkit copying its last
  frame into the next buffer costs one op.
- **Text** is sent as glyph outlines in em units, taken from the same face at 1024 units per em
  without hinting, so variations and synthetic bold or oblique come out as cairo draws them.
  Colour glyphs have no outlines and are recorded as `unsupported` regions.
- **Windows.** A wl_shm buffer is an image surface over shared memory. The recorder names it by
  the inode and offset of that memory, and it interposes libwayland-client's
  `wl_proxy_marshal_flags` and `wl_proxy_marshal_array_flags` to see `wl_shm` pools and buffers
  and `wl_surface` attach and commit. A commit of a known buffer is written as `present`, and
  the recorded ops are written out before the commit leaves the process. Applications built
  against libwayland older than 1.20 use the older marshalling calls, which are not observed:
  their ops are recorded but no `present` marks their frames.
- **The draw socket.** Without `CABOOSE_DRAW_CAPTURE` the recorder connects to caboose-display's
  draw socket (`CABOOSE_DRAW_SOCKET`, or the display instance's directory found from
  `XDG_RUNTIME_DIR` and `WAYLAND_DISPLAY` inside a sandbox) and records only while the
  compositor asks it to, from the frame after it asks, in a fresh stream that starts with
  `begin` ([docs/draw.md](../../docs/draw.md#the-draw-socket)). It reads the compositor's
  commands at each commit, and from drawing calls at most five times a second for X11
  applications. It never waits on the socket: past 64 MiB unsent it stops for good, and the
  application draws on unrecorded.
- **Nothing to record into, nothing recorded.** With neither a capture file nor a draw socket
  the hooks only forward calls. Every cairo, FreeType and libwayland function is resolved with `dlsym`, so the
  library links only libc and is inert in processes without cairo.

| Variable | Effect |
| --- | --- |
| `CABOOSE_DRAW_SOCKET` | caboose-display's draw socket (set in the launch environment) |
| `CABOOSE_DRAW_CAPTURE` | Append the draw lists to this file instead; `%p` becomes the process id |
| `CABOOSE_DRAW_PIXELS=1` | After each `present`, also write the pixels the application drew (`pixels` op), for checking |

## Install

`install.sh` (as root, in the image build, after `guest/scroll-reporter/install.sh`) puts the
recorder in `/opt/caboose/draw/lib`, where caboose-display finds it and adds it to the
`LD_PRELOAD` of the launch environment, and adds it to the system-wide Flatpak override's
`LD_PRELOAD` beside the scroll reporters, with its directory read-only.
`guest/container/Dockerfile` builds it in a stage of its own. Preloaded everywhere, it stays
idle until a client that draws draw lists connects.

## Build

    guest/draw/build.sh [OUT]     # default guest/draw/build

Needs a C compiler, `pkg-config` and the cairo, FreeType and wayland-client headers. The
recorder links nothing but libc; the replayer links cairo.

## Check

    guest/draw/tests/check.sh [gtk3|writer]...

Without Weston it runs `caboose-display` from `$CABOOSE_DISPLAY_BIN` as the compositor, with
Xwayland. `CABOOSE_DRAW_BIN` names a directory holding an already built recorder and replayer,
for a host without a compiler. `--diff DIR` on the replayer writes each comparison as an image:
the application's picture dimmed, with what differs in red.

It runs each application under a headless Weston with the recorder preloaded and pixel capture
on. Then it replays the capture at 1× and compares it with the pixels the application drew.
Replay and application rasterize with the same cairo, so a difference is something the recording
missed; glyphs differ by anti-aliasing only, because the replay fills outlines where cairo
rasterizes glyphs. It replays again at 3× to PNGs; a window surface that never had a `present`
(an X11 window) is written as its final state. `writer` runs LibreOffice with the backend it
picks. With the `gen` (X11) backend LibreOffice draws its buffers with cairo but puts them on
screen with X11 copies, which the recorder does not see; with `gtk3` it is a cairo application
throughout. It prints, per application, the op counts and
bytes by kind, the frames, the share of pixels that differ by more than 8 levels, the PSNR, and
the area drawn without a record. Needs `weston`, `python3-gi` with GTK 3 and `python3-cairo`;
`writer` also needs `libreoffice-writer` and `libreoffice-gtk3`.
