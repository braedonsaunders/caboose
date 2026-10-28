# Caboose Display

Caboose's own display server and stream: every Linux window rendered on the GPU, encoded
straight from GPU memory, and shown on the phone or TV as its own native surface. It
replaces Xvfb + Xpra wherever a host has a GPU. Xpra stays as the fallback for hosts
without one, behind the same window model in the app.

## Why

Measured on an RTX 4080 under WSL (2026-10-28): a 4K Chromium video reached the phone at
~16 fps. NVENC HEVC encoded every frame in a few milliseconds, and Xpra sent every frame
Chromium painted. The limit was Xvfb. Chromium rendered on the GPU, read each 33 MB frame
back to the CPU and wrote it into Xvfb's memory, and then Xpra read it out again. Parsec,
Sunshine and Steam Link stream 4K60 from weaker GPUs because their frames never leave GPU
memory between render and encode. Caboose Display does the same per window.

## What it is

```
 apps (Wayland, and X11 through Xwayland)
   │ linux-dmabuf buffers, wl_surface damage, frame callbacks
   ▼
 caboose-display   (headless Wayland compositor, Rust + Smithay, inside the computer)
   ├ one Stream per toplevel / popup: its committed dmabuf + damage
   ├ Encoder per stream, zero copy from the dmabuf:
   │     NVENC (CUDA external memory) · VA-API (dmabuf import) · Vulkan Video ·
   │     software (x264/x265, for hosts without a GPU; then the buffers are wl_shm)
   ├ text mode: static content re-sent as lossless tiles once motion stops
   ├ pacing: frame callbacks released on the client's vsync ticks
   └ input: wl_touch, tablet-v2 (Pencil), text-input-v3 (IME), pointer, keyboard
   │ Caboose Display Protocol (below) over the existing host relay
   ▼
 CabooseKit (iOS) · VideoToolbox HEVC/AV1 → CAMetalLayer (EDR/HDR), per window
```

The compositor composites nothing. It is a window and buffer broker. The phone and TV are
the compositors, which is how each window stays a native surface.

## Host requirements, and what each gets

| Host | Rendering | Buffers | Encode | Expected |
| --- | --- | --- | --- | --- |
| Linux, NVIDIA (`CABOOSE_GPU=nvidia`) | EGL/Vulkan on the GPU | dmabuf | NVENC (zero copy) | 4K60+ |
| Linux, Intel/AMD (`dri`) | Mesa | dmabuf | VA-API (zero copy) | 4K60 on recent parts |
| Bare-metal microVM with VFIO GPU | as above, inside the VM | dmabuf | as above | 4K60, VM isolation |
| WSL2 (`wsl`) | Mesa D3D12 on `/dev/dxg` | wl_shm (no DRM/GBM in WSL) | NVENC/D3D12-VA after a CPU copy | same ceiling as today |
| No GPU (`none`, microVM default) | pixman / llvmpipe | wl_shm | x264/x265 | CPU-bound, like Xpra |

Zero copy on WSL waits on the cross-process buffer sharing that WSL does not have today
(active work: a Cookiekira/niri issue to validate a GLES → D3D12-VA proof of concept,
microsoft/wslg#469). A box that needs zero-copy 4K runs Linux natively.

## Caboose Display Protocol (v0)

Binary frames over the `/v1/display` WebSocket. Version is negotiated in `hello`.
Little-endian. The type is one byte, then a u32 length, then the payload. Metadata
is CBOR; frames carry raw NAL units.

Server → client
- `hello { version, displays, encoders: ["hevc","av1","h264"], features }`
- `window.create { id, parent?, kind: toplevel|popup|dialog, title, app_id, icon?, geometry, min/max, fullscreen }`
- `window.update { id, …changed fields }` · `window.destroy { id }`
- `frame { id, codec, keyframe, pts_us, rect, crop, data }`. One encoded picture of one
  window, in Annex-B, with `crop` for encoder padding (NVENC pads 2160 → 2176).
- `tile { id, rect, format: png|webp-lossless, data }`. Lossless refresh of static content.
- `cursor { id?, image, hotspot } | cursor.named { name }` (text cursors drive the iOS keyboard)
- `clipboard`, `notification`, `audio { codec: opus, pts_us, data }` (Opus, in sync with `pts_us`)

Client → server
- `hello { version, decoders, displays: [{ id, width, height, scale, refresh_hz, hdr }] }`
- `vsync { display, t_us }`. The client's display ticks; frame callbacks are released on them.
- `ack { id, pts_us, decoded_us }`. Flow control and latency accounting.
- `configure { id, geometry, fullscreen?, maximized?, activated? }` · `close { id }` · `request_keyframe { id }`
- input: `touch { id, slot, phase, x, y, force?, radius? }`, `pencil { …, pressure, tilt, azimuth }`,
  `pointer { id, x, y, buttons, scroll{dx,dy,precise} }`, `key { keysym, pressed, mods }`,
  `text { commit, preedit?, cursor? }` (text-input-v3: autocorrect, dictation, CJK)

## Milestones

1. **Compositor skeleton.** Headless Smithay compositor with Xwayland, wl_shm + dmabuf, and one stream per toplevel with a software encoder. The iOS client renders windows over the relay. Runs on any Linux.
2. **Zero copy on a Linux GPU.** dmabuf → NVENC (CUDA) and dmabuf → VA-API, plus Vulkan Video where present. Success: Chromium 4K60 video at ≥55 fps on the phone/TV, under 30 ms from frame to decode on a LAN.
3. **Input that is native.** wl_touch multitouch, Pencil via tablet-v2, text-input-v3 IME from the iOS keyboard.
4. **Pacing and polish.** Frame callbacks paced on vsync (ProMotion 120 Hz), HDR/EDR, lossless text tiles, Opus audio in sync with video.
5. **Default where it can be.** The host picks Caboose Display when the computer has a GPU and the image has it, and falls back to Xpra otherwise. The app supports both.
