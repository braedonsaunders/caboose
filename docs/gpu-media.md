# Phone-decoded video in GPU windows

When the phone renders an application's window (the live GPU path, [gpu-live.md](gpu-live.md)),
the application's video is not decoded on the computer. The application decodes through the
Caboose VA-API driver as through any hardware decoder; the driver sends the compressed
bitstream to the phone, the phone decodes it in hardware with VideoToolbox, and the decoded
picture appears in exactly the Vulkan image the application's compositor samples. The
application composites the video itself, so its controls, subtitles, rounded corners,
transforms, CSS filters and WebGL or canvas uses of the video are drawn as they would be
on a local GPU.

```
 computer (one process, e.g. Chromium's GPU process)                       phone
 ┌──────────────────────────────┐   media stream (compressed units)   ┌──────────────────────┐
 │ caboose_drv_video.so ─────────┼─────────────── broker ─────────────▶│ VideoToolbox decoder │
 │   surface = dmabuf + identity │                                     │   pictures by        │
 │            │ (shared memory)  │                                     │   (token, surface)   │
 │ libvulkan_gfxstream.so        │   Vulkan stream: … LATCH, submit …  │          ▼           │
 │   imports the dmabuf, reads   ┼─────────────── broker ─────────────▶│ latch: copy picture  │
 │   its identity at each submit │                                     │ into the image, on   │
 └──────────────────────────────┘                                     │ the app's queue      │
                                                                       └──────────────────────┘
```

The byte layouts are in `guest/vaapi/src/gpu_media.h` and pinned by
`guest/vaapi/tests/gpu-media-vectors.txt`, which the driver's and the phone's tests both
check. All integers are little-endian.

## When a stream is decoded on the phone

At `vaInitialize` the driver connects to the GPU broker (`$CABOOSE_GFXSTREAM_SOCKET`) and asks
the phone what it decodes. A decoder context (`vaCreateContext`) is decoded on the phone when

- the media connection is open and the phone decodes the codec, bit depth and size, and
- the Caboose Vulkan driver is loaded in the process, so whatever samples the surfaces latches
  the phone's pictures (Chromium's GPU process, mpv `--vo=gpu-next` through Vulkan, GL
  applications through Zink).

Otherwise the stream takes the path in [codec-passthrough.md](codec-passthrough.md): decoded
locally into the surfaces. While the media connection is open, the driver advertises only the
VA profiles the phone decodes, so an application that picks its codec by the hardware decoders
it has (a site asking `MediaCapabilities`) picks one the phone decodes. `CABOOSE_VA_GPU=0` turns phone decoding off; `CABOOSE_VA_MODE=decode`
decodes everything locally.

## Surface identity

Every surface the driver allocates is one linear dmabuf (udmabuf, or a vgem buffer where the
kernel has no udmabuf, as on WSL): the luma plane, the interleaved chroma plane, and a final
4096-byte page whose first 64 bytes say what the planes mean.

| Offset | Size | Field |
| --- | --- | --- |
| 0 | 8 | ASCII `CBVAID01` |
| 8 | 4 | Sequence: odd while the record is being rewritten |
| 12 | 4 | State: 0 empty, 1 decoded on the phone, 2 pixels |
| 16 | 16 | Token of the media connection |
| 32 | 8 | Serial: nonzero, increasing for every new picture or new pixels |
| 40 | 4 | VA surface ID |
| 44 | 4 | Fourcc, `NV12` or `P010` |
| 48 | 2+2 | Width, height of the picture |
| 52 | 4 | Pitch of both planes, in bytes |
| 56 | 4 | Offset of the chroma plane |
| 60 | 4 | Zero |

The decoder rewrites the record with a sequence lock: it makes the sequence odd, writes the
fields, and makes it even again. A reader copies the fields between two equal even reads of the
sequence. The record lives in the buffer, not in a socket or a shared table, so any process
that imports the dmabuf can read it; nothing ties the consumer to the decoder's address space,
connection or lifetime.

- At `vaEndPicture` in phone mode, the shown surface becomes state 1 with a new serial; a
  separate decode target (AV1 film grain) becomes empty.
- Whenever local decoding writes a picture's pixels into a surface, it becomes state 2 with a
  new serial.
- A new surface, or one whose picture could not be rebuilt, is state 0: nothing to show.

Surfaces the application allocates itself (imported through `vaCreateSurfaces`) carry no record.

## Media stream

The driver opens an ordinary stream of the GPU broker: it sends the broker's 48-byte local
hello and waits for its echo, which the broker sends once the phone has opened the stream for
the process (see [gpu-live.md, "Connection and authority"](gpu-live.md#connection-and-authority)).
The broker therefore authenticates, binds, bounds and retires it like the process's Vulkan
streams; it does not look at the bytes. In place of Vulkan's client-flags word the stream
starts with `CBVM` (`0x4d564243`), and the phone hands it to its media decoder instead of the
Vulkan decoder. Records follow, each a `u32` type, a `u32` payload length (at most 16 MiB) and
the payload.

Driver to phone:

| Type | Record | Payload |
| --- | --- | --- |
| `0x01` | HELLO | `u32 version` (1), `u8 token[16]` (random, names this connection's pictures) |
| `0x02` | OPEN | `u32 stream`, `u8 codec` (1 H.264, 2 HEVC, 3 VP9, 4 AV1), `u8 bit_depth`, `u8 chroma` (1 = 4:2:0), `u8 0`, `u16 width`, `u16 height` |
| `0x03` | UNIT | `u32 stream`, `u32 seq`, `u32 surface`, `u32 flags`, `u64 serial`, `u16 width`, `u16 height`, `u32 0`, data |
| `0x04` | CLOSE | `u32 stream` |
| `0x05` | SURFACE_GONE | `u32 surface`: the phone forgets that surface's picture |

Phone to driver:

| Type | Record | Payload |
| --- | --- | --- |
| `0x81` | CAPS | `u32 version` (1), `u32 count` (at most 16), then per format `u8 codec`, `u8 max_bit_depth`, `u16 0`, `u16 max_width`, `u16 max_height` |
| `0x82` | FAIL | `u32 stream`, `u32 reason` (1 the phone cannot decode this format, 2 its decoder keeps failing) |
| `0x83` | REPLAY | `u32 stream`: send again from the last key frame |

The phone answers HELLO with CAPS, listing only formats it decodes in hardware. A UNIT is one
access unit in decode order, exactly as in [codec-passthrough.md](codec-passthrough.md#the-driver):
Annex-B for H.264 and HEVC with parameter sets at random access points, a VP9 frame or
superframe, an AV1 temporal unit. `flags` are those of `FRAME` there (key, hidden, replay).
`serial` is the serial the unit's surface names, and `surface` is the surface the application
shows the picture in. A surface's serials never decrease from one unit to the next; a picture
may be sent more than once with the same serial (a shown AV1 forward key frame, or a replay).

The phone keeps, per connection token and surface, the latest picture it has decoded and its
serial, until a later unit names the surface, SURFACE_GONE arrives or the connection closes.
FAIL makes the driver decode that stream locally from its key-frame buffer, so every surface
the application still holds gets its pixels (state 2); a failed connection does that for every
phone stream. The phone sends FAIL 2 after its decoder has failed three times in ten seconds,
and REPLAY when a single picture fails to decode.

## Latch

Before each `vkQueueSubmit` and `vkQueueSubmit2`, the Vulkan driver reads the identity of every
dmabuf imported into an image of that device. For each image whose identity changed since its
last latch, it puts one LATCH packet into its own Vulkan stream, immediately before the
submission:

| Offset | Size | Field |
| --- | --- | --- |
| 0 | 4 | `CBVL` (`0x4c564243`) |
| 4 | 4 | Packet size in bytes |
| 8 | 8 | The queue's wire handle |
| 16 | 4 | Entry count (1–64) |
| 20 | 4 | Zero |

Each entry is the image's wire handle (`u64`), `u32 kind`, `u32 planes` (1 luma, 2 chroma,
3 both: which of the surface's planes the image holds), `u32 fourcc`, `u16 width`, `u16 height`,
then for kind 1 (picture) `u8 token[16]`, `u32 surface`, `u32 0`, `u64 serial`, and for kind 2
(pixels) `u32 pitch`, `u32 chroma offset`, `u64 length` and that many bytes: the planes the
image holds, luma first, each `pitch` bytes per row; the chroma offset is where the chroma rows
start within those bytes (`pitch × height` when both planes are carried, 0 for a chroma-only
image). A packet is at most 16 MiB, the phone's largest stream packet; pixels that do not fit
(4K 10-bit and larger) are not carried and the image keeps its contents.

Images over dmabufs that carry no identity (not the driver's surfaces) are latched as pixels
whenever their bytes differ from those last sent, so a foreign NV12 or P010 dmabuf's contents reach the
phone.

LATCH is not a Vulkan command and carries no sequence number; the phone's stream reader handles
it before the Vulkan decoder sees the stream. Because it travels in the same ordered stream as
the submission, the image is filled after every earlier submission on that queue has been
queued and before the submission that follows: the order a GPU's implicit dmabuf
synchronization gives a local driver. The application has received the frame from its decoder
before it records work that samples it, so the identity it reads already names the picture.

On the phone, a picture latch waits until the named picture is decoded (normally it was decoded
before the application even received the frame), then copies it on the application's queue:
VideoToolbox's IOSurface planes are imported into MoltenVK images (`VK_EXT_metal_objects`) and
copied with `vkCmdCopyImage` into the application's image, between barriers that order it after
earlier reads and before later ones, leaving the image in `GENERAL` layout. A pixels latch copies
the carried bytes through a staging buffer. A picture that does not arrive within 200 ms, or
whose surface already holds a newer picture, leaves the image's contents as they were. Resources
of a latch are released when its copy completes, by a reclaimer that holds the image and device
alive only until then.

## Synchronization, seeking and pausing

The application presents the frame that samples the picture when its own clock says to, and
that frame reaches the phone as any other frame does: video and the application's drawing are
synchronized with each other by construction. Seeking and pausing are the application's: a
seek resets its decoder, the driver starts again from the next key frame, and the phone's
decoder resynchronizes on it; a paused video is a surface whose identity does not change, so it
is never latched again.

## Limits

- **Only Caboose Vulkan consumers see the picture.** A process that maps the exported dmabuf with
  the CPU, or hands it to a consumer other than the Caboose Vulkan driver, sees an empty picture.
  VA-level readback (`vaGetImage`, mapping a derived image) is detected and switches the stream to
  local decoding.
- **Formats.** The phone decodes what VideoToolbox decodes in hardware: H.264 (8-bit), HEVC (Main,
  Main 10) and, on devices with the decoder, AV1 and VP9. Anything else is decoded locally.
- **Colour.** VA carries no colour description (see [codec-passthrough.md](codec-passthrough.md#limits));
  the phone copies the coded samples unchanged and the application applies its own colour
  conversion, as it does for any hardware decoder's output.
- **AV1 is one picture late**, as in passthrough: a unit is sent when the next picture reveals
  its reference refresh.
