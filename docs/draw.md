# Caboose Draw lists

A draw list is 2D drawing recorded on the computer as commands (paths, strokes, gradients,
images, glyph outlines, clips, compositing operators and offscreen surfaces), so that another
renderer can draw the same picture at its own density. The imaging model is the common subset
of PDF, cairo, Skia and the HTML canvas, so each op maps to one call in any of them. No
toolkit, X11 or Vulkan semantics are on the wire.

The writer is [guest/draw/src/cdl.h](../guest/draw/src/cdl.h). The cairo recorder
(`libcaboose-draw-cairo.so`, [guest/draw](../guest/draw/README.md)) writes draw lists to
caboose-display's draw socket, which forwards them to a client that draws them
([display.md, Draw lists](display.md#draw-lists)), or to a capture file;
`caboose-draw-replay` draws a capture again. The Rust reader is
`caboose_display_protocol::draw`.

## The draw socket

`draw.sock` in the display instance's private directory
(`$XDG_RUNTIME_DIR/caboose-display/<Wayland socket>/`), owner-only, named to applications by
`CABOOSE_DRAW_SOCKET`. A recorder connects when it loads and records nothing until the
compositor asks: the compositor writes `R` and a generation (`u32` LE) when a client that
draws connects, and `S` when it leaves. A recorder starts a fresh stream at its next frame
with a `begin` op of that generation; the compositor drops bytes before it. A recorder never
waits on the socket: what it cannot send stays queued, and past 64 MiB queued it stops
recording and closes.

## Stream

A stream is a sequence of ops. Each op is `op: u8`, `len: u32`, then `len` bytes of payload. A
reader skips an op it does not know. Integers are little-endian, and every coordinate, colour
and length is an IEEE-754 `f32`. A stream is one process's recording, in the order it drew.

Composite fields:

| Field | Encoding |
| --- | --- |
| matrix | six `f32`: `xx, yx, xy, yy, x0, y0` (cairo's order: `x' = xx·x + xy·y + x0`, `y' = yx·x + yy·y + y0`) |
| path | `nverbs: u32`, `npoints: u32`, `verbs: u8[nverbs]`, then `npoints` × (`x: f32`, `y: f32`). Verbs: `0` move (1 point), `1` line (1), `2` quadratic (2), `3` cubic (3), `4` close (0) |
| stops | `n: u32`, then `n` × (`offset, r, g, b, a`: `f32`), colours not premultiplied |
| source | `kind: u8`, then by kind (below) |

Sources:

| Kind | Payload |
| --- | --- |
| `0` solid | `r, g, b, a` (`f32`, not premultiplied) |
| `1` linear | `x0, y0, x1, y1`, `extend: u8`, matrix, stops |
| `2` radial | `cx0, cy0, r0, cx1, cy1, r1`, `extend: u8`, matrix, stops |
| `3` surface | `surface: u32`, `extend: u8`, `filter: u8`, matrix |
| `4` image | `image: u64`, `extend: u8`, `filter: u8`, matrix |

A source's matrix maps user space to the source's own space: gradient space for gradients, and
the source's pixels for surfaces and images. `extend` is `0` none, `1` repeat, `2` reflect,
`3` pad. `filter` is cairo's (`0` fast … `5` gaussian).

## Ops

| Op | Name | Payload |
| --- | --- | --- |
| `0x01` | `surface` | `id: u32`, `w: u32`, `h: u32`, `kind: u8`: `0` an offscreen created transparent, `1` a window's wl_shm buffer (created transparent; `present` shows it), `2` a surface drawn into without knowing what was there before (an X11 window). Declared before its first use. `w` and `h` are `0` when unknown |
| `0x02` | `free` | `id: u32` |
| `0x03` | `target` | `id: u32`: the surface later drawing ops draw into |
| `0x04` | `clip` | `n: u32`, then `n` items, intersected: `0` rectangle (`x, y, w, h` in the target's pixels) or `1` path (matrix, `rule: u8`, `antialias: u8`, path). `n = 0` is no clip. Applies to the current target until the next `clip` or `target` |
| `0x05` | `fill` | `operator: u8`, `rule: u8`, `antialias: u8`, matrix, source, path |
| `0x06` | `stroke` | `operator: u8`, `antialias: u8`, matrix, `width: f32`, `cap: u8`, `join: u8`, `miter: f32`, `ndash: u32`, `dash_offset: f32`, `dashes: f32[ndash]`, source, path |
| `0x07` | `paint` | `operator: u8`, `alpha: f32`, matrix, source |
| `0x08` | `mask` | `operator: u8`, matrix, source, mask source (its alpha) |
| `0x09` | `glyphs` | `operator: u8`, matrix, font matrix, `font: u64`, source, `n: u32`, then `n` × (`glyph: u32`, `x: f32`, `y: f32`) |
| `0x0A` | `unsupported` | `reason: u32` (`1` a source pattern with no encoding, `2` a source surface whose pixels could not be read, `3` glyphs without outlines), `x, y, w, h`: the target's pixels drawn without a record |
| `0x20` | `image` | `hash: u64`, `w: u32`, `h: u32`, `format: u8` (`0`: premultiplied RGBA8), pixels |
| `0x21` | `glyph` | `font: u64`, `glyph: u32`, path in em units, y down |
| `0x30` | `present` | `surface: u32`, `wl_surface: u32`: the window buffer `surface` was committed to the Wayland surface with this protocol id |
| `0x31` | `pixels` | `surface: u32`, `w: u32`, `h: u32`, premultiplied RGBA8: what the application really drew, for checking |
| `0x32` | `begin` | `generation: u32`: a fresh recording; nothing before it is referred to after it |

- **Matrices.** A drawing op's matrix maps user space to the target's pixels. Paths, glyph
  positions and the stroke's width and dashes are in user space, so a non-uniform matrix gives
  an elliptical pen, as in cairo. A renderer drawing at `k` times the pixels prepends a scale
  by `k`.
- **Operators, rules, antialias, caps, joins** use cairo's enum values: operators `0` clear to
  `28` HSL luminosity, fill rule `0` winding and `1` even-odd, antialias `0` default to `6`
  best, cap `0` butt to `2` square, join `0` miter to `2` bevel.
- **Glyphs.** A run draws each glyph's outline through the font matrix (em units to user space),
  translated to the glyph's position, and fills them with the winding rule. `font` identifies a
  face with its variation coordinates and synthesis. It is a hash of the face's sfnt `head`
  table (or the bytes of a memory font), its index, glyph count, units per em, names, design
  coordinates, synthesis flags and variation settings, so every process names the same face
  the same way. A `glyph` op precedes the first run that uses it.
- **Resources.** `image` and `glyph` are sent once per stream, before the first op that uses
  them, and keyed by content: an image by the XXH64 (seed 0) of its pixels, a glyph by
  `XXH64(font as 8 bytes LE, seed = glyph)`.
- **Surfaces.** Offscreens and wl_shm window buffers start transparent (toolkits allocate
  buffers from fresh, zeroed shared memory); a renderer holds each one at the same density as
  the window. A buffer used as a source (a toolkit copying its last frame into the next buffer)
  is a `surface` source, so no pixels travel. A surface of kind `2` holds what was there before
  its first recorded op, which only the computer has.
