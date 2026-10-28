# caboose_drv_video.so: the codec passthrough VA-API driver

A libva driver that does not decode. Players (Chromium, Firefox, mpv, VLC, GStreamer,
FFmpeg) decode through it as through any hardware decoder; it rebuilds each picture's
compressed bitstream from the VA buffers and sends it to caboose-display, which forwards
it to the phone or TV to decode in hardware. The surfaces the player gets back hold a
marker that tells the compositor where on screen, and when, each frame is shown. When a
stream cannot be passed through, the driver decodes it itself with libavcodec.

The contract with caboose-display (socket, marker, binding, fallback, limits) is
[docs/codec-passthrough.md](../../docs/codec-passthrough.md); the design it serves is
"Video, for every app" in [docs/display.md](../../docs/display.md).

## Layout

| Path | What |
| --- | --- |
| `src/driver.c` | libva entry point and objects; streams, the key-frame buffer, the switch to local decoding |
| `src/surface.c` | Surface memory (memfd, exported through `/dev/udmabuf`), imported dmabufs, export descriptors |
| `src/marker.c` | The marker painter and the reference detector that caboose-display links |
| `src/sink.c`, `src/proto.h` | The video socket |
| `src/h264.c`, `src/hevc.c`, `src/vp9.c`, `src/av1.c` | Bitstream rebuilders, one per codec; each file's header says what it rebuilds and what it refuses |
| `src/local.c` | Local decoding (the fallback) with libavcodec |
| `src/bits.c` | Bit writer and reader, Exp-Golomb, NAL escaping |
| `tools/cbva-capture.c` | `split` a capture into elementary streams; `serve` a stub caboose-display |
| `tools/cbva-detect.c` | Run the detector on a screenshot |
| `tests/unit.c` | Unit tests: bit I/O, escaping, the marker code, the detector on synthetic screens |
| `tests/roundtrip.sh`, `tests/cases/` | Bit-exact round trips per codec through `ffmpeg -hwaccel vaapi` |
| `tests/e2e.sh` | mpv, Chromium and GStreamer on a GPU, with the stub compositor and the detector |

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
render nodes through. `make BUILD=dir` builds elsewhere. The driver links libva, libdrm,
libavcodec and libavutil.

## Run

`make install` puts `caboose_drv_video.so` next to the system's VA drivers (libva's
`driverdir`, `/usr/lib/x86_64-linux-gnu/dri` on Debian; `DESTDIR` is honoured), or point
`LIBVA_DRIVERS_PATH` at the build directory. caboose-display sets
`LIBVA_DRIVER_NAME=caboose` (and `GST_VA_ALL_DRIVERS=1`, for GStreamer) in the sessions it
runs (only when the driver is installed and its socket is listening); both guest images
build and install the driver together with caboose-display. Without a listening
compositor the driver does not initialise, and players decode in software as they would
without a hardware decoder.

| Variable | Effect |
| --- | --- |
| `CABOOSE_VIDEO_SOCKET` | The compositor's socket (default `$XDG_RUNTIME_DIR/caboose-video.sock`) |
| `CABOOSE_VA_SINK=path` | Write the socket's messages to a file instead (tests); `cbva-capture split` reads it |
| `CABOOSE_VA_MODE=decode` | Decode every stream locally; initialises without a compositor |
| `CABOOSE_VA_LOG=1` | Log streams, mode switches and refused bitstreams to stderr |

Exporting surfaces needs read-write access to `/dev/udmabuf` (the `udmabuf` kernel module,
and the device in a container). Without it the players that render through GL or Vulkan
copy frames out instead, which is readback, so those streams decode locally.

## Test

```sh
guest/vaapi/scripts/dev.sh make check                        # unit tests + every round trip
guest/vaapi/scripts/dev.sh tests/roundtrip.sh h264 vp9      # some codecs
CABOOSE_VAAPI_DRI=1 guest/vaapi/scripts/dev.sh tests/e2e.sh # players, on a GPU
```

**Round trips** (`tests/cases/<codec>.cases`): each case encodes a reference clip with
ffmpeg, then decodes it through the driver twice. With frames kept in VA surfaces, the
rebuilt bitstream the driver forwards is decoded in software and must match the source
decode bit for bit, frame for frame (for VP9 and AV1, every source frame must be present
and the only extras are hidden frames the source never shows). With frames read back, the
driver switches to local decoding at the first readback and the frames ffmpeg reads must
match the source bit for bit. Both run headless on any machine, against a VA display on
Xvfb.

**End to end** (`tests/e2e.sh`, needs a Mesa GPU render node): a headless Weston with the
GL renderer, `cbva-capture serve` as the compositor, and

- mpv `--hwdec=vaapi --vo=gpu`: frames flow, surfaces are exported as dmabufs, the
  screenshot's marker gives the 960 x 540 video rectangle, and a `REPLAY` resends from a key
  frame;
- mpv `--hwdec=vaapi-copy`: the first readback switches the stream to local decoding and
  the screen shows the real video;
- mpv after a compositor `DECODE` at frame 30: the same, mid-stream;
- Chromium playing a `<video>` in H.264, VP9, AV1 and HEVC: the marker gives the element's
  800 x 450 rectangle, and what Chromium fed the driver decodes to the source's frames
  exactly (with the sandbox on, using the guest's seccomp profile, as in the command at the top of
  the script);
- GStreamer `vah264dec`, `vah265dec`, `vavp9dec`, `vaav1dec`: passthrough exact with frames
  in VA memory; and H.264 readback (frames downloaded to system memory) bit-exact through
  local decoding.

Results on the development machine (AMD Radeon HD 7450, Mesa r600, Debian 13 container,
2026-10-28):

| Check | Result |
| --- | --- |
| Unit tests | pass |
| H.264 round trips: CBP, Main/CABAC, High 8x8, 1080p (1088 coded), 4 slices, weighted prediction, JVT scaling lists, B-pyramid with 8 refs, interlaced (MBAFF; x264 cannot make field pictures, so PAFF is untested), High 10, open GOP | 11/11 bit-exact, passthrough and readback |
| HEVC round trips (x265): default, closed and open GOP with CRA/RASL, Main 10, slices + WPP, 1080p, no WPP, scaling lists, lossless, a tools mix (transform skip, SAO off, AMP, QP offsets), odd size (crop), 6 refs + 8-frame pyramid, weighted prediction, temporal layers, PPS changes, SPS-indexed RPS (two-pass `multi-pass-opt-rps`) | 17/17 |
| HEVC JCT-VC conformance bitstreams (run by hand: tiles, dependent slices, list modification, PCM, long-term refs, EOS) | 53/62 exact; 4 change resolution and match once their contexts' streams are joined; 1 needs a crop; 3 (and a spliced stream) output extra pictures `no_output_of_prior_pics_flag` would have dropped; RPS_D differs in 5 of 68 frames in libavcodec only (see hevc.c) |
| VP9 round trips: profile 0 two-pass with alt-refs (6 hidden frames shown later), realtime (3 hidden frames never shown), 2 tile columns, profile 2 10-bit | 4/4 |
| AV1 round trips (libaom, SVT-AV1, rav1e): alt-refs, forward key frames, realtime + cyclic AQ, tiles (uniform and not), 10-bit, film grain (two encoders), screen content, intra block copy, error resilience, global motion, 128x128 superblocks + quantizer matrices + delta-q, lossless, superres, switch frames, reference scaling | 19/19 |
| mpv 0.40, Chromium 156 (sandboxed and not), GStreamer 1.26 | 12/12 end-to-end checks |
| Reference: the same ffmpeg decode on the Mesa r600 VA driver | identical VA call sequence and statuses; r600's own decode is bit-exact with software, as is the driver's local decode |

Driver cost, `ffmpeg -hwaccel vaapi -hwaccel_output_format vaapi -f null` against software
decode of the same 10 s H.264 clips (testsrc2, x264 veryfast, 20 Mb/s, 4 CPUs):

| Clip | Software decode, CPU per frame | Through the driver, CPU per frame | Forwarded bytes vs source |
| --- | --- | --- | --- |
| 1920 x 1080 | 9.7 ms | 0.3 ms (demuxing excluded) | +0.02 % (in-band parameter sets) |
| 3840 x 2160 | 20 ms | 1.0 ms, mostly allocating and marking 20 4K surfaces once | +0.02 % |

## Limits

See [docs/codec-passthrough.md, "Limits"](../../docs/codec-passthrough.md#limits): GPU-side
readback (canvas, WebGL) is invisible to the driver and is the compositor's to catch;
protected (hardware DRM) sessions are not offered; colour primaries, transfer and HDR
metadata are not in VA; AV1 is forwarded one picture late; no `vaPutSurface` and no video
processing entry point; export needs `/dev/udmabuf`; imported surfaces must be linear.
Bitstreams refused per codec (the app then decodes in software):

- H.264: `pic_order_cnt_type` 1, slice groups (FMO), 4:2:2 and 4:4:4.
- HEVC: anything but 4:2:0 at 8 or 10 bits, multi-layer streams, partial slice data, an
  inline RPS predicted from the SPS sets without `st_rps_bits`, SPS long-term candidates
  VA's references do not identify, slice headers whose reference counts disagree with VA.
- VP9: none beyond the profiles advertised (0 and 2).
- AV1: profiles 1 and 2 (4:4:4, 4:2:2, 12-bit), monochrome, large-scale tile, reference
  slots changed in a way the stream does not explain.

Behaviours to know:

- AV1 pictures are held until the next one shows their `refresh_frame_flags`. A paused AV1
  video shows the client the picture before the one the app is showing until playback
  resumes or the app closes its decoder.
- HEVC `no_output_of_prior_pics_flag` is cleared, so the client may decode pictures the app
  never shows (the compositor never presents them); a CRA that the app treated as the start
  of a sequence is sent as BLA.
- Local decoding starts from the key frame before last that the driver kept. Pictures from
  earlier GOPs that an app reads back late keep their marker, and so do the RASL pictures
  of an HEVC CRA when the switch lands on it.
