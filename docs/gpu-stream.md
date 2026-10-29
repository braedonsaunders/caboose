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
| `gpu.create`, `gpu.data`, `gpu.destroy`, `gpu.ack`, `gpu.seek` | [display.md, "GPU streams"](display.md#gpu-streams) |
| The player and the device's copy of streams | CabooseKit, `Sources/CabooseKit/GPU` and `UI/GPUStreamView`, over `apps/ios/GPUStream` |

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
buffer. With no client that renders streams connected, the FIFO is not read and the
application waits in its next Vulkan call. Otherwise everything read is appended to a spool in
`~/.cache/caboose/gpu-streams/`: without pause until the window is announced (an application
uploads much of its data before it maps its window, and nothing can be acknowledged before),
and after that only while the spool is less than 64 MiB ahead of the client.

A client whose hello says `gpu: true` gets `gpu.create { id, window, nonce }` after the
window's `window.create`, then the stream from its first byte as `gpu.data { id, offset, data }`,
and answers with `gpu.ack { id, offset }` as it consumes it. At most 4 MiB are sent beyond the
last acknowledgement, so the application runs at the pace the client renders. A client that
connects later replays the spool from the start, unless it kept its replay of the stream
through a lost connection ([Resuming](#resuming)). `gpu.destroy` follows when the application
ends or its window closes, and the spool is deleted with it.
Client acknowledgements apply only to the connection, window and stream that consumed
the bytes; queued callbacks from a replaced connection are ignored.

A spool holds at most `--gpu-spool-limit` bytes (2 GiB unless set). A stream that would
outgrow it ends: its spool is emptied, `gpu.destroy { id, reason: "spool-limit" }` tells the
client (a client that meets the window later gets `gpu.create` and that `gpu.destroy` at once),
and what the application still writes is read and dropped, so the application keeps running
while its window shows nothing.

While a client renders a window's stream, the window sends no pictures.

## Resuming

A client that loses its display connection keeps the replay of each stream it was playing, so
that the next connection to the same caboose-display process continues the stream where the
replay stands instead of replaying it from its first byte.

- **The stream's name.** `gpu.create` carries `nonce`: 16 random hexadecimal characters that
  name the stream (its launcher and spool) and no other. A stream id names one window's
  binding; the nonce is what a claim must match.
- **The accepted offset.** When the connection goes, the client drops the stream bytes it has
  received that its replay has not taken (still queued, or not yet handed to the replay) and
  waits for the replay to take the chunk it is being handed. The replay's *accepted offset* is
  then exact: every byte before it went into this replay (`cgpu_player_feed` returned for it),
  and none after. A replay that failed or was stopped cannot continue and is not kept; nor is a
  stream from a server that named no nonce.
- **The claim.** The next `hello` lists each kept replay whose accepted offset is settled in
  `gpu_resume { epoch, streams: [{ id, nonce, offset }] }`, with the epoch of the server hello
  the replays came from. A replay still taking its last chunk when the hello is sent is not
  claimed.
- **The answer.** caboose-display honours a claim when `epoch` is its own, the stream with that
  `id` is announced in the hello's burst of `window.create`s and `gpu.create`s, `nonce` is that
  stream's, the stream has not outgrown its spool, and `offset` is at most the spool's length.
  The stream's `gpu.create` then carries `resume: offset`: its first `gpu.data` starts at that
  offset and acknowledgements count from it. A claim counts only for the hello's burst. Every
  other stream starts from its first byte, with a `gpu.create` without `resume`.
- **The client.** A `gpu.create` whose `resume` equals the kept replay's accepted offset and
  whose `nonce` is the kept stream's continues that replay with the new connection's bytes.
  Without `resume`, the client discards the kept replay and starts a new one from the stream's
  first byte. A kept stream that the burst does not announce has ended, and a server hello
  with another epoch, or with none, discards every kept replay.
- **Fences.** Acknowledgements and claims count only on the connection that made them:
  caboose-display acts on nothing a replaced connection sends, and the client ignores what a
  replay reports for a connection it has left.

A client that does not claim (an older one, for example) gets every stream from its first
byte, as before; one that does not know `nonce` and `resume` ignores them.

## The device's copy

CabooseKit keeps the bytes of each stream it receives on the device, in
`Caches/CabooseGPUStreams/<server epoch>/<stream id>`, with a record beside it
(`<stream id>.json`: the epoch, the id, the nonce, and how many bytes from the stream's first
the data holds). Each chunk is written just before the replay takes it. Every 4 MiB, and when
the connection goes or the stream ends, the data is synchronized and the record replaced
atomically (written to a temporary file, then renamed); data past the recorded length is never
used.

A new replay of a stream (after the app relaunched, or when a kept replay could not continue)
for which the device holds a copy from the same server epoch under the same nonce takes the
copy first: a chunk at a time, at the pace the replay takes them, replaying and presenting
every frame as it would from the network, since the player has no way to replay without
presenting. Meanwhile it acknowledges nothing, so caboose-display sends no more than its 4 MiB
window of the stream's start, which the client drops. Once the replay has taken the copy, the
client sends `gpu.seek { id, nonce, offset }` with the offset the replay accepted (all of the
copy, or less if part of it could not be read), and takes the stream from the connection from
there. caboose-display continues the stream at that offset, forward or back, when the stream
with that `id` is announced to the connection, `nonce` is its own and the spool holds that
much; otherwise it ignores the message. A `gpu.create` that resumes a stream for a replay the
device no longer has, without a copy of the stream's start, is answered with `gpu.seek` at
offset 0.

The copy is bounded. A stream stops being kept at 2 GiB (caboose-display's default spool
limit; a stream that outgrows the computer's own limit ends), and all of them at 4 GiB
(`GPUStreamCache.budget` changes it): the least recently used streams that are not open are
removed to make room, and a stream that still has none stops being kept, with what it
recorded. A write or record that fails (a full disk) stops keeping that stream and removes
it; the stream plays on from the connection. The copy lives in Caches, which iOS may purge.

A stream's copy is removed by its `gpu.destroy`, by a replay that failed on it, by a stream of
the same id under another nonce, and by a server hello with another epoch or none; the app
removes them all on signing out and on switching computers. A stream that ended while no
connection could say so stays until one of these, or eviction, removes it.

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
- **The whole stream is kept, up to the limit.** A spool grows for as long as the application
  runs, up to `--gpu-spool-limit`, and a client that connects later without a replay of the
  stream to resume replays all of it before the current frame. A stream longer than the limit
  cannot be rendered at all.
- **A new replay replays everything.** A replay that starts again, from the device's copy or
  from the spool, replays and presents every frame from the stream's start before the current
  one. The device's copy saves the transfer, not the time.
- **Device resources.** Streams use separate replay threads, Vulkan instances and devices.
  Their GPU and memory costs accumulate on the client.
