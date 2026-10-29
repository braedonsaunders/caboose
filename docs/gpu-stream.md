# GPU streams

A GPU stream renders a Linux application's window on the client's GPU. The application runs
on the computer as usual, against a Vulkan driver that renders nothing. A capture layer writes
every Vulkan call it makes, and every write it makes into mapped GPU memory, into a stream;
caboose-display relays the stream to the client, which replays it on its own GPU (Metal,
through MoltenVK) into the application's window. The computer does no rendering and no video
encoding for the window; the client draws it at its own resolution.

| Piece | Where |
| --- | --- |
| `caboose-gpu-run`, the launcher | [guest/gpu](../guest/gpu/README.md) |
| The relay, its spool and its flow control | caboose-display, `compositor/src/game.rs` |
| `gpu.create`, `gpu.data`, `gpu.destroy`, `gpu.ack` | [display.md, "GPU streams"](display.md#gpu-streams) |
| The player | CabooseKit, `Sources/CabooseKit/GPU` and `UI/GPUStreamView`, over `apps/ios/GPUStream` |

## On the computer

`caboose-gpu-run [--title TITLE] [--app-id APP_ID] [--] COMMAND [ARGS...]` makes a FIFO in
`$XDG_RUNTIME_DIR/caboose-gpu/<pid>.gfxr`, says `hello` on the game socket with
`stream: <that path>` in place of a game's `root` and `entry` (see
[game-handoff.md, "The game socket"](game-handoff.md#the-game-socket)), and waits for the
first `mode`:

- `handoff`: a client renders Vulkan streams. The launcher becomes the application (`exec`,
  so the pid is the one caboose-display bound) with `VK_ICD_FILENAMES` pointing at the
  driver that renders nothing, the GFXReconstruct capture layer writing into the FIFO without
  compression, and X11 as the window system: an Xwayland window maps without a buffer, which
  this driver never presents. When the client's capabilities are installed as
  `profile.json`, the Khronos profiles layer shows the application the client's GPU.
- `local`, or no answer within five seconds: the launcher becomes the application with the
  environment unchanged, so it renders on the computer and its window streams as video.

The launcher's connection stays open in the application; its end tells caboose-display the
stream is over.

## The relay

caboose-display opens the FIFO for reading and writing, so it never sees end of file between
writes, and binds the stream to the first top-level window whose process is the launcher's
(the Wayland client's pid, or an X11 window's `_NET_WM_PID`, else its X client's pid through
the XRes extension). The window is shown once X maps it, although the driver never gives it a
buffer. The FIFO is read while a client that renders streams is connected, from before the
window exists (an application uploads much of its data first); with none connected the
application waits in its next Vulkan call. Everything read is appended to a spool in `~/.cache/caboose/gpu-streams/`.

A client whose hello says `gpu: true` gets `gpu.create { id, window }` after the window's
`window.create`, then the stream from its first byte as `gpu.data { id, offset, data }`, and
answers with `gpu.ack { id, offset }` as it consumes it. At most 4 MiB are sent beyond the
last acknowledgement, and the FIFO is read only while the spool is less than 64 MiB ahead of
it, so the application runs at the pace the client renders. A client that connects later
replays the spool from the start. `gpu.destroy` follows when the application ends or its
window closes, and the spool is deleted with it.

While a client renders a window's stream, the window sends no pictures.

## Limits

- **The driver answers, not the client's GPU.** Fences and semaphores signal at once, and
  queries and memory the GPU writes read back as zeros, so an application that reads
  occlusion queries or GPU results back to the CPU draws as if nothing were visible or
  computed.
- **Vulkan only, X11 window.** Applications render through Vulkan: native Vulkan, or
  Direct3D through DXVK and vkd3d-proton under Wine or Proton. OpenGL applications are not
  streamed.
- **The client's GPU.** Without a profile the application sees a device that supports
  everything; it may choose formats or features the client cannot render (desktop BC texture
  compression on an iPhone, geometry shaders on any Apple GPU).
- **Linear images.** An application that writes pixels straight into a linearly tiled image
  lays them out for the driver here, whose row pitch is not the client's; those images show
  wrong on the client. Uploads through a buffer (what games and engines do) are unaffected.
- **The whole stream is kept.** A spool grows for as long as the application runs, and a
  client that connects later replays all of it before the current frame.
