# caboose_drv_video.so: the Caboose VA-API driver

A libva driver through which applications' video is decoded on the phone. Players
(Chromium, Firefox, mpv, VLC, GStreamer, FFmpeg) decode through it as through any hardware
decoder. It rebuilds each picture's compressed bitstream from the VA buffers. In a process
whose windows the phone renders (the Caboose Vulkan driver is loaded and the GPU broker's
phone decodes the format), it sends that bitstream to the phone over a media stream of the
GPU broker, and each surface's identity page names the phone's picture, which the Vulkan
driver latches into the image that samples the surface. Every other stream, and a stream
the application reads back or the phone fails, is decoded by the driver itself with
libavcodec into the application's surfaces.

The contract (when a stream is decoded on the phone, the media wire, surface identities,
the latch, and the fallback to local decoding) is [docs/gpu-media.md](../../docs/gpu-media.md).
The driver is written in C and links libva, libdrm, libavcodec and libavutil.

## Layout

| Path | What |
| --- | --- |
| `src/driver.c` | libva entry point and objects; streams, the key-frame buffer, the switch to local decoding |
| `src/surface.c` | Surface memory (memfd exported through `/dev/udmabuf`, or a vgem buffer), identity pages, imported dmabufs, export descriptors |
| `src/gpu.c`, `src/gpu_media.h` | The media connection to the phone; the wire, identity and latch layouts shared with the Vulkan driver |
| `src/h264.c`, `src/hevc.c`, `src/vp9.c`, `src/av1.c` | Bitstream rebuilders, one per codec; each file's header says what it rebuilds and what it refuses |
| `src/local.c` | Local decoding with libavcodec |
| `src/bits.c` | Bit writer and reader, Exp-Golomb, NAL escaping |
| `src/proto.h` | Codec ids and unit flags, and the capture format the test tools share |
| `tools/cbva-phone.c` | A stand-in broker and phone for the media connection; checks the contract and writes what it receives as a capture |
| `tools/cbva-capture.c` | `split` a capture into elementary streams |
| `tests/gpu-media.c`, `tests/gpu-media-vectors.txt` | The media wire and identity page against golden vectors, and the identity's sequence lock under a concurrent writer |
| `tests/av1-state.c` | Source-level AV1 OBU/reference-state checks, including a paused held picture requested after an older surface |
| `tests/unit.c` | Unit tests: bit I/O and escaping |
| `tests/roundtrip.sh`, `tests/cases/` | Bit-exact round trips per codec through `ffmpeg -hwaccel vaapi` |
| `tests/consumer-stub.c` | A library named like the Vulkan driver, preloaded so a test player takes the phone path |

## Build

Everything builds and runs in the dev container (Debian 13, the guest's release), so the
host needs only Docker:

```sh
docker build -t caboose-vaapi-dev guest/vaapi
guest/vaapi/scripts/dev.sh make            # build/caboose_drv_video.so and the tools
```

`dev.sh` runs as the calling user with this directory at `/src`, passes `/dev/udmabuf`
through when the host has it, caps the container at 4 CPUs and 4 GiB
(`CABOOSE_VAAPI_CPUS`, `CABOOSE_VAAPI_MEMORY`), and with `CABOOSE_VAAPI_DRI=1` passes the
render nodes through. `make BUILD=dir` builds elsewhere.

## Run

`make install` puts `caboose_drv_video.so` next to the system's VA drivers (libva's
`driverdir`, `/usr/lib/x86_64-linux-gnu/dri` on Debian; `DESTDIR` is honoured), or point
`LIBVA_DRIVERS_PATH` at the build directory. Both guest images build the driver with
caboose-display and install it in `/usr/lib/x86_64-linux-gnu/dri`; the microVM image also
loads the `udmabuf` module and gives the `caboose` group access to `/dev/udmabuf`, and the
container gets `/dev/udmabuf` on `nvidia` and `dri` hosts that have it. A player uses the
driver when its environment names it (`LIBVA_DRIVER_NAME=caboose`, and
`GST_VA_ALL_DRIVERS=1` for GStreamer) and names the GPU broker's socket.

At `vaInitialize` the driver opens the media connection to the phone. Without one it does
not initialise, and players decode in software as they would without a hardware decoder;
`CABOOSE_VA_MODE=decode` makes it initialise anyway and decode every stream locally.

| Variable | Effect |
| --- | --- |
| `CABOOSE_GFXSTREAM_SOCKET` | The GPU broker's socket; the driver opens the media connection to the phone through it |
| `CABOOSE_VA_MODE=decode` | Decode every stream locally; initialises without a media connection |
| `CABOOSE_VA_GPU=0` | Never decode on the phone |
| `CABOOSE_VA_LOG=1` | Log streams, mode switches and refused bitstreams to stderr |

Exporting surfaces needs read-write access to `/dev/udmabuf` (the `udmabuf` kernel module,
and the device in a container) or, where the kernel has no udmabuf (WSL), to vgem's primary
node (`/dev/dri/card*` of the `vgem` module), whose dumb buffers are exported instead.
Without either, the players that render through GL or Vulkan copy frames out instead, which
is readback, so those streams decode locally. Chromium skips vgem render nodes when it looks
for a VA device; give it the node with `--hardware-video-device-path=/dev/dri/renderD128`.

## Test

```sh
guest/vaapi/scripts/dev.sh make check                    # unit tests + every round trip
guest/vaapi/scripts/dev.sh tests/roundtrip.sh h264 vp9  # some codecs
CBVA_CASES='av1-aom-realtime av1-aom-altref' guest/vaapi/scripts/dev.sh tests/roundtrip.sh av1
```

`make check` runs `build/unit`, `build/av1-state` (the AV1 provisional sequence contract,
on synthetic tile bytes: it checks headers and reference state and is not a decoder
conformance test), `build/gpu-media` against the golden vectors, and every round trip.

**Round trips** (`tests/cases/<codec>.cases`): each case encodes a reference clip with
ffmpeg, then decodes it through the driver three times, against a VA display on Xvfb:

- `phone`: frames kept in VA surfaces, with `tools/cbva-phone` as the phone and the
  consumer stub preloaded. The rebuilt bitstream the phone receives is decoded in software
  and must match the source decode bit for bit, frame for frame (for VP9 and AV1, every
  source frame must be present and the only extras are hidden frames the source never
  shows), and the phone must see no violation of the media contract.
- `phone-rb`: frames read back with the phone connected. The first readback moves the
  stream from the phone to local decoding, and the frames ffmpeg reads must match the
  source bit for bit.
- `local`: `CABOOSE_VA_MODE=decode`; the frames ffmpeg reads must match the source bit for
  bit.

`CBVA_CASES` selects space-separated exact case names; a selection running no cases fails.
The round trips cover:

- **H.264:** Constrained Baseline, Main with CABAC, High with 8x8 transforms, 1080p (1088
  coded), 4 slices, weighted prediction, JVT scaling lists, a B-pyramid with 8 references,
  interlaced MBAFF, High 10 (decoded locally: the phone decodes H.264 at 8 bits), and open
  GOP. x264 cannot produce field pictures, so PAFF is not covered.
- **HEVC** (x265): default, closed and open GOP with CRA/RASL, Main 10, slices with WPP,
  1080p, no WPP, scaling lists, lossless, a tools mix (transform skip, SAO off, AMP, QP
  offsets), an odd size (crop), 6 references with an 8-frame pyramid, weighted prediction,
  temporal layers, PPS changes, and SPS-indexed RPS (two-pass `multi-pass-opt-rps`).
- **VP9:** profile 0 two-pass with alt-refs (hidden frames shown later), realtime (hidden
  frames never shown), 2 tile columns, and profile 2 10-bit.
- **AV1** (libaom, SVT-AV1, rav1e): alt-refs, forward key frames, realtime with cyclic AQ,
  uniform and non-uniform tiles, 10-bit, film grain from two encoders, screen content,
  intra block copy, error resilience, global motion, 128x128 superblocks with quantizer
  matrices and delta-q, lossless, superres, switch frames, and reference scaling.

For 10 s H.264 test clips at 20 Mb/s, the forwarded bitstream is about 0.02% larger than
the source: the parameter sets sent in band.

## Limits

- GPU-side readback (canvas, WebGL) is invisible to the driver.
- Protected (hardware DRM) sessions are not offered.
- Colour primaries, transfer and HDR metadata are not in VA.
- There is no `vaPutSurface` and no video processing entry point.
- Export needs `/dev/udmabuf` or vgem; imported surfaces must be linear.

Bitstreams refused per codec (the app then decodes in software):

- H.264: `pic_order_cnt_type` 1, slice groups (FMO), 4:2:2 and 4:4:4.
- HEVC: anything but 4:2:0 at 8 or 10 bits, multi-layer streams, partial slice data, an
  inline RPS predicted from the SPS sets without `st_rps_bits`, SPS long-term candidates
  VA's references do not identify, slice headers whose reference counts disagree with VA.
- VP9: none beyond the profiles advertised (0 and 2).
- AV1: profiles 1 and 2 (4:4:4, 4:2:2, 12-bit), monochrome, large-scale tile, reference
  slots changed in a way the stream does not explain.

Against the JCT-VC HEVC conformance bitstreams (run by hand, not part of `make check`:
tiles, dependent slices, list modification, PCM, long-term references, EOS), 53 of 62
rebuild exactly. Of the rest, 4 change resolution and match once their contexts' streams
are joined; 1 needs a crop; 3 (and a spliced stream) output extra pictures that
`no_output_of_prior_pics_flag` would have dropped; and RPS_D differs in 5 of 68 frames, in
libavcodec only (see `src/hevc.c`).

Behaviours to know:

- AV1 pictures are sent to the phone one picture late: the driver holds a picture until the
  next one reveals its `refresh_frame_flags`. Local decoding supplies a held picture's
  pixels on sync, export or readback without refreshing reference slots; requests for
  another sequence do not consume that provisional picture.
- HEVC `no_output_of_prior_pics_flag` is cleared, so the phone may decode pictures the app
  never shows; a CRA that the app treated as the start of a sequence is sent as BLA.
- Local decoding after a switch starts from the key frame before last that the driver kept.
