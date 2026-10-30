# Codec passthrough

Codec passthrough is experimental machinery for forwarding original compressed video.
Current composition admission requests local server decode for all marker streams. The computer ships a VA-API driver, `caboose_drv_video.so`, that
players decode through as through any hardware decoder. In capture mode it rebuilds
each picture's compressed bitstream from the VA buffers and sends it to caboose-display,
which contains the machinery to forward it as a `passthrough` video stream (the `video.*` messages in
[display.md, "Video streams"](display.md#video-streams)). The experimental client path decodes in hardware and layers the video into the window
at the moment the app presents each frame. The code,
its build and its tests are in [guest/vaapi](../guest/vaapi/README.md).

This document is the contract between the driver and caboose-display: the socket, the
placeholder marker, how a stream is bound to a window, and how a stream falls back.

## Composition admission

The compositor currently answers every driver `OPEN` with `ACCEPT` mode 1 (local
server decode), including headless sessions and clients advertising `video_decoders`.
The marker protocol carries identity and approximate geometry, not a lossless
foreground plane, alpha, occlusion ordering or an atomic composition generation.
A flattened pixel `C = alpha * foreground + (1 - alpha) * marker` cannot recover
both foreground and alpha. Exact marker-colored controls are indistinguishable
from uncovered video; tolerance-based gray matching also loses translucent edges,
color conversions and scaled/cropped samples. Recognition is not a composition mask.

Local decode gives the application real video pixels before it draws controls,
subtitles and menus. The ordinary window/motion paths carry that complete composition;
the iOS window texture stays opaque and does not punch holes based on gray pixels.
There is no marker-mask wire message or enabled phone passthrough path. The socket
and experimental rebuilder/capture machinery below remain available for isolated tests.

## The driver

Apps load it with `LIBVA_DRIVER_NAME=caboose`. caboose-display sets that variable in the
launch environment it writes, with `GST_VA_ALL_DRIVERS=1` (GStreamer's `va` plugin
otherwise accepts only drivers on its allow-list) and `CABOOSE_VIDEO_SOCKET`, when the
driver is installed where libva looks and its socket is listening. Nothing else should
set it, because the driver refuses to initialise when no compositor is listening (see
[Fallback](#fallback)).

It advertises VLD decoding of H.264 (Constrained Baseline, Main, High, High 10), HEVC
(Main, Main 10), VP9 (profiles 0 and 2) and AV1 (Main), up to 8192 x 8192. What each codec
needs rebuilt:

| Codec | From the app | Rebuilt by the driver |
| --- | --- | --- |
| H.264 | each slice NAL unit, whole | SPS and PPS from the picture parameters and IQ matrix; the PPS id and default reference counts from the slice headers |
| HEVC | each slice NAL unit | VPS, SPS and PPS; slice headers rewritten so short-term reference sets are coded in the slice (VA does not carry the SPS sets) |
| VP9 | the whole frame | nothing; a hidden frame gets a one-byte `show_existing_frame` appended (a superframe) |
| AV1 | tile data | sequence header, frame header and tile group OBUs; `refresh_frame_flags` is inferred from the next picture, so each frame is sent one picture late |

Each unit goes out in decode order: H.264 and HEVC as an Annex-B access unit, with the
parameter sets in band at every random access point and whenever they change; VP9 as a
frame or superframe; AV1 as a temporal unit of OBUs with size fields. A unit decodes, in a
software decoder, to exactly the pixels the app's own decoder would produce; the tests check
that bit for bit.

What VA does not carry, and so the client does not get: timestamps (presentation is
signalled by the app's own display of the frame, below), the visible crop of H.264/HEVC
(the client clips to what the app shows), colour primaries and transfer characteristics
(VA gives the matrix for AV1 only; everything else is assumed BT.709 SDR), HDR metadata,
and the display aspect ratio.

## The socket

The driver connects at `vaInitialize` to `$CABOOSE_VIDEO_SOCKET`, by default
`$XDG_RUNTIME_DIR/caboose-video.sock`, a Unix stream socket that caboose-display listens
on. Each caboose-display instance has its own socket: the owner's display uses the
default, and the agent seat `$XDG_RUNTIME_DIR/caboose-video-agent.sock` (set by its unit,
or by `caboose-session` in the container). SO_PEERCRED gives the compositor the app's pid, to match it to its Wayland client.
Connecting at initialisation means the connection exists before Chromium's GPU sandbox
engages.

Every message is a type byte, a little-endian `u32` payload length, and a little-endian
payload of fixed layout; `FRAME` and `HELLO` end in variable-length data. The source of
truth is `guest/vaapi/src/proto.h`.

Driver to compositor:

| Type | Message | Payload |
| --- | --- | --- |
| `0x01` | `HELLO` | `u16 version` (1), `u16 0`, `u32 pid`, program name (UTF-8, to the end) |
| `0x02` | `OPEN` | `u32 stream`, `u8 codec` (1 H.264, 2 HEVC, 3 VP9, 4 AV1), `u8 profile` (0), `u8 bit_depth`, `u8 chroma` (1 = 4:2:0), `u16 width`, `u16 height` (coded size at creation) |
| `0x03` | `FRAME` | `u32 stream`, `u32 seq`, `u32 surface`, `u8 flags`, `u8[3] 0`, `u64 t_us` (CLOCK_MONOTONIC at decode), `u16 width`, `u16 height` (coded size of this picture), data |
| `0x04` | `SURFACE` | `u32 surface`, `u32 0`, `u64 st_dev`, `u64 st_ino` of the surface's dmabuf; sent when the app first exports it |
| `0x05` | `CLOSE` | `u32 stream`, `u8 reason` |
| `0x06` | `SURFACE_GONE` | `u32 surface` |

Compositor to driver:

| Type | Message | Payload |
| --- | --- | --- |
| `0x81` | `ACCEPT` | `u32 stream`, `u8 tag` (0-63, unique among the compositor's live streams), `u8 mode` (0 passthrough, 1 decode locally) |
| `0x82` | `DECODE` | `u32 stream`, `u8 reason` (0 the client cannot decode the codec, 1 no marker tag is free, 2 the client keeps failing to decode it): decode this stream locally from now on |
| `0x83` | `REPLAY` | `u32 stream`: send again from the last key frame |

`seq` counts the stream's pictures from 0 in decode order, one per `vaEndPicture` (an
interlaced H.264 frame decoded as two fields is two pictures; the second field's `seq`
names the frame). `FRAME` flags: `0x01` key (decoding can start here), `0x02` hidden (the
app did not show the picture when it decoded it; the data still makes a decoder output it,
so the client can hold it until it is presented, which may be never), `0x04` replay (sent
in answer to `REPLAY`; the original was already sent). `CLOSE` reasons: 0 the app
destroyed its decoder, 1 the app read pixels back, 2 the compositor sent `DECODE`, 3 the
bitstream cannot be rebuilt (the app decodes it in software), 4 no `ACCEPT` in time or the
socket failed. After any `CLOSE` but reason 0 the stream continues in the app as ordinary
decoded video.

The driver waits up to one second for `ACCEPT` when the app creates a decoder. With no
answer it decodes that stream locally and sends `CLOSE` with reason 4. A write that blocks
for two seconds, or a closed socket, switches every stream to local decoding.
caboose-display answers `OPEN` with `ACCEPT` mode 1 under the composition admission
rule above. The capture tool can accept mode 0 for isolated bitstream testing.

## The marker

A surface the app gets back holds no picture. It holds a marker that names the frame:

- an 8 x 8 grid of tags over the whole coded frame; each tag is 7 x 7 modules, so the frame
  is 56 x 56 modules, module `(i, j)` covering luma columns `[i*W/56, (i+1)*W/56)` and rows
  `[j*H/56, (j+1)*H/56)`;
- each module dark (Y = 16) or bright (Y = 56), limited range, chroma neutral: black and
  dark grey on screen, whatever the colour conversion;
- in a tag, the border ring is a checkerboard (bright where `x + y` is even), and the 5 x 5
  interior holds 25 bits, bit `(y-1)*5 + (x-1)` bright when set: bits 0-2 the tag's column,
  3-5 its row, 6-11 the stream's tag from `ACCEPT`, 12-17 `seq` mod 64, 18-24 a CRC-7
  (x^7 + x^3 + 1, zero initial value, over bits 17 to 0, most significant first).

Every tag carries its own position, so any tag that survives on screen gives the whole
frame's rectangle, through scaling (to about a quarter of the coded size, or up), stretching,
`object-fit: cover` crops and partial cover. `seq` mod 64 names the exact picture the app is
showing. The driver rewrites only the modules that change between pictures.

`guest/vaapi/src/marker.c` holds the painter and the reference detector:
`cb_mark_detect()` takes an 8-bit luma plane and stride and returns, per frame found, the
stream tag, `seq`, the frame's rectangle on screen and the visible clip. Its unit tests
cover scaled, stretched, cropped, full-range, dithered and mirrored frames over busy
backgrounds. caboose-display carries a port of it (`guest/display/compositor/src/video/marker.rs`),
run at half resolution and refined at full resolution around each hit; its scripted
`passthrough` check runs `cbva-detect` on the same decoded window picture and requires the
two to agree.

## Binding and presentation

caboose-display binds a stream to a window by its pixels. The app composites the
decoded surface into its own window (Chromium, Firefox, mpv `--vo=gpu`, X11 players
through Xwayland), and the compositor runs the detector over the damaged parts of the
window buffers of the player's process family while a stream is open. The rectangle and
clip come from the tags; the H.264 1080p padding rows (1920 x 1088 coded), and anything
else the app crops, show up as the clip. A stream is bound to one rectangle in one window
at a time, and is unbound when its marker has been missing from three consecutive
scans of that window.

`SURFACE` names a decode surface's dmabuf so that a compositor can recognise a
`wl_buffer` that is the surface itself (a video subsurface: mpv `--vo=dmabuf-wayland`,
GStreamer's `waylandsink`). caboose-display's pixman renderer offers only linear RGB
dmabuf formats, so applications do not present NV12 decode surfaces to it; it receives
`SURFACE` and binds by pixels.

The moment the compositor sees a picture on screen is its presentation time,
`video.present { id, seq, pts_us }` on the server clock. The app has already scheduled that
moment against its audio clock, so the client stays in sync by presenting video and audio
with the same delay. The client draws the video above the window picture, within the
clip (see [display.md, "Video streams"](display.md#video-streams)), so controls or
subtitles the app draws over the video area are hidden while the stream is shown.

## Fallback

A stream falls back to local decoding: the driver decodes its own rebuilt bitstream with
libavcodec into the app's surfaces, so the app has an ordinary decoder and the compositor
sees ordinary video, which stays in the window picture or becomes a detected `motion`
stream.
The switch happens:

- **When the app reads pixels back** through VA: `vaGetImage`, or mapping a `vaDeriveImage`
  image of a surface that holds a marker (FFmpeg's `hwdownload`, mpv `--hwdec=vaapi-copy`,
  thumbnailers). Reason 1.
- **When the compositor sends `DECODE`:** a newly connected client cannot decode the
  codec, no marker tag is free (64 live streams), or the client keeps reporting decode
  errors (three `video.keyframe` requests within 10 s). Reason 2.

A bitstream the driver cannot rebuild (H.264 `pic_order_cnt_type` 1, slice groups, 4:2:2
and 4:4:4, and the per-codec cases in [guest/vaapi](../guest/vaapi/README.md)) cannot be
decoded locally either. The stream closes with reason 3, `vaEndPicture` fails from then
on, and the app falls back to its own software decoder.

The switch is seamless: the driver keeps the bitstream since the key frame before last
(64 MiB at most) and decodes it at once, so every surface the app still holds gets its
pixels. It takes pixels from the decoder as soon as a picture is decoded, ahead of
reordering, because an app may read a picture back before a reordering decoder would
output it. A stream never switches back.

With no compositor listening, `vaInitialize` fails and apps decode the way they do without
a hardware decoder. `CABOOSE_VA_MODE=decode` instead makes every stream decode locally, for
debugging.

## Limits

- **Pixels read through the GPU are not seen.** A page that draws a video into a canvas and
  reads it with `getImageData`, or uploads it to WebGL, gets the marker, not the picture;
  only VA-level readback is detectable. The compositor does not detect a marker the app
  has transformed (WebGL, CSS filters, canvas effects), so such a video shows its marker
  in the window picture.
- **Protected content.** The driver does not advertise VA protected sessions, so
  hardware-DRM (Widevine L1 style) playback never reaches it. Decrypt-only CDMs, such as
  Chromium's Widevine L3 on Linux, hand the decoder clear bitstream, which is passed
  through like any other.
- **Colour.** Primaries, transfer and HDR metadata are not in VA. 10-bit streams arrive as
  10-bit, but an HDR (PQ/HLG) stream is shown as SDR unless the compositor learns its colour
  elsewhere.
- **AV1 latency.** Each AV1 picture is sent when the next one is decoded, one picture late
  (VA does not carry `refresh_frame_flags`; the next picture's references reveal them).
  This can leave experimental passthrough one picture behind at pause. Local decode
  supplies a held picture on sync/export/readback with a provisional shown unit that
  refreshes no reference slots, then commits the actual refresh mask when known. A
  request for another sequence does not consume that unit. Context destruction flushes
  once; no inactivity timer invents refresh flags or a show-existing reference.
- **Apps that render through `vaPutSurface`** (mpv `--vo=vaapi`, old VLC outputs) get
  `VA_STATUS_ERROR_UNIMPLEMENTED` and use their GL paths instead. No video processing
  entry point (`VAEntrypointVideoProc`) is offered.
- **Exporting surfaces needs `/dev/udmabuf`.** Without it, `vaExportSurfaceHandle` fails and
  players fall back to copying frames out, which is readback and so local decoding.
- **Imported surfaces must be linear.** Apps that allocate their own buffers (Chromium on
  some GPUs) and hand tiled ones to `vaCreateSurfaces` are refused, and decode in software.
- **Chromium needs a DRM render node** to open VA at all, so on hosts without one (`none`,
  WSL) Chromium's video stays in the window picture or becomes a `motion` stream.
