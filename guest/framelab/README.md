# Frame lab

Frame lab runs a fixed matrix of applications on a Caboose computer and scores each one
the same way: frame pacing, input latency, stalls and their causes, whether the picture
is right, and what it costs. It measures shared mechanisms, not pages: every app is
launched the generic way (its desktop entry or its command, with the seat's launch
environment) and measured through instrumentation the seat already has. Nothing in it is
specific to one app beyond the app's arguments and its input script in
[`matrix.json`](matrix.json).

| File | Is |
| --- | --- |
| `framelab.py` | The pure logic: diagnostic line parsing, scorecards, stall attribution, picture comparison, the summary table |
| `framelab-guest.py` | The guest side: runs the matrix inside a computer, as the seat's owner |
| `framelab-drive.py` | The driver, on the Mac the phone is attached to: wakes the computer, launches the phone app, runs the guest side, collects and scores |
| `matrix.json` | The matrix |
| `check.sh` | The headless check, in a disposable container without a phone |
| `standin-broker.py` | The broker's present trace without a phone, for `check.sh` |
| `test_framelab.py` | Unit tests for `framelab.py` |

## The matrix

| Id | App | Input | Picture compared |
| --- | --- | --- | --- |
| `chromium-wikipedia` | Chromium, a long Wikipedia article (a local article with `--offline`) | wheel scrolling down and back | yes |
| `chromium-youtube` | Chromium, a YouTube watch page (skipped with `--offline`) | none, animated | no |
| `firefox` | Firefox, the same article | wheel scrolling | yes |
| `gtk4` | gtk4-widget-factory (GTK 4) | Ctrl+Page Down/Up through its pages | yes |
| `qt-quick` | qml6 with a 2000-row ListView (Qt 6) | wheel scrolling | yes |
| `vscode` | Visual Studio Code (Electron) on a 5000-line file | wheel scrolling | yes |
| `vkcube` | vkcube (Vulkan) | none, animated | no |
| `glxgears` | glxgears (OpenGL, through Zink where the seat routes it) | none, animated | no |
| `vkquake` | vkQuake, from its desktop entry (present on the GPU acceptance seat) | none, animated | no |
| `terminal` | xfce4-terminal running `cat` (drawn on the CPU) | typed characters, echoed | yes |
| `video` | mpv looping a generated 720p30 clip | none, animated | no |

An app the computer lacks is reported as not installed. Each entry sets how long to wait
for its window (`ready_s`), to let it settle (`warmup_s`) and to measure (`measure_s`).

## What a scorecard holds

One JSON file per app (`<app>.json`), and `summary.md`, a table with one row per app.

- **`path`**: where its frames were seen. `gpu` when the GPU broker forwarded its presents
  to the phone, `video` when the compositor sent its pictures to the client, `none` when
  nothing drew.
- **`pacing`**: frames per second and the gap between frames (p50, p95, max) over the
  measured span. On the GPU path these are the presents from the guest
  (`CABOOSE_GPU_PRESENT`), and also the rate and gaps of the phone's present results; on the
  video path, the pictures sent with new content (not those that only sharpen it). When the broker has only its two-second
  `CABOOSE_GPU_PRESENT_RATE` counters, the rate and the largest gap come from them.
- **`input`**: for each injected input, the time to the first frame after it, to the
  phone's result for that frame (GPU path), and to the phone's glass when the phone reports
  presentation times (`caboose-framelab: present`, below); p50, p95 and max. Input is
  injected at the compositor through its control socket, the same seat input the phone's
  events become. Animated apps have none.
- **`stalls`**: every interval of 100 ms or more where the app should have drawn and did
  not, with a cause. An animated app should always draw, so any frame gap counts. An
  input-driven app owes a picture from each input until its next frame (at most 2 s, for
  an input that changes nothing). Causes, first match wins:
  `phone_decode` (the phone spent 50 ms or more decoding commands inside the stall,
  `CABOOSE_GPU_DECODE_TIMING`), `guest_read` (the app's processes were blocked reading
  replies for at least half the stall in the `CABOOSE_READ_PROFILE` window covering it),
  `app_busy` (the app used at least half a core) and `app_idle` (none of these). The
  evidence for each is in the stall's entry.
- **`resources`**: the CPU of the app's process tree in the computer (percent of one core,
  mean and the largest half-second sample) and the bytes per second on its stream: the GPU
  stream to the phone (`CABOOSE_GPU_STREAM`) or the encoded window pictures.
- **`correctness`**: the app's picture after it settles, before any input, compared with
  the same scene drawn on the computer's CPU (the app run again without the phone's Vulkan
  driver: its driver-list entries and socket variables removed from the launch
  environment and `VK_LOADER_DRIVERS_DISABLE=*gfxstream*`). Both are reduced to a 64x64
  luma grid; the score is mean SSIM over 8x8 tiles and the share of cells more than 10%
  apart, and it passes at SSIM 0.9 and 5% changed. `candidate_source` says where the
  compared picture came from: the phone, or the compositor's own screenshot when the phone
  has none.

## Where the numbers come from

All guest times are the computer's CLOCK_MONOTONIC.

- The compositor's control socket: `windows`, `screenshot`, injected input, and `frames`,
  its timeline of each window's commits and sent pictures and of input
  ([architecture.md § Displays](../../docs/architecture.md#displays)).
- The GPU broker's present trace, switched on for the run by creating
  `$XDG_RUNTIME_DIR/caboose-gpu-present-trace` and read from the broker's stderr, which it
  shares with the display's log ([gfxstream README](../gpu/gfxstream/README.md)). Without
  it the broker's `CABOOSE_GPU_PRESENT_RATE` lines are used.
- The app's own output: `CABOOSE_READ_PROFILE=1` is in its environment, and the phone's
  driver prints its blocking-read profile every two seconds.
- `/proc` for the CPU of the app's process tree, sampled every half second.
- The phone's console, kept by the driver: `CABOOSE_GPU_DECODE_TIMING` lines (with
  `CABOOSE_PRIVATE_GPU_MEMORY_AUDIT=1`), and `caboose-framelab: present window=W seq=S
  presented_ns=P now_ns=N` lines with `CABOOSE_FRAMELAB=1`, where P is when the present
  was shown and N when the line was written, both on the phone's clock. With
  `CABOOSE_FRAMELAB=1` the phone also writes each live GPU window's settled picture (the
  same twice, a second apart) to `Documents/framelab/<window>-<serial>.png` and prints
  `caboose-framelab: picture window=W serial=S file=F now_ns=N`
  (`CabooseKit/GPU/FrameLabPictures.swift`); the driver copies the directory out and
  compares the one nearest the guest's own picture in place of the compositor's.

Phone lines have no clock in common with the computer. The driver stamps each one when it
arrives, and stamps every guest event the same way; the smallest difference between a
guest event's arrival and its own time is the offset between the two clocks (an
overestimate by that event's transit time, tens of milliseconds over ssh). Phone times are
therefore good for attributing a stall of 100 ms or more, not for sub-frame timing.
`caboose-framelab: present` lines carry their own age (N − P), so their glass time does
not include the console's delay.

## Run it on the phone

From a checkout on the Mac the phone is attached to, with the computer's host machine
reachable over ssh as root:

```sh
python3 guest/framelab/framelab-drive.py --computer c-9c400ccda8 \
  --device <devicectl device id> --out /tmp/framelab-$(date +%H%M) \
  [--apps chromium-wikipedia,vkcube,gtk4,terminal] [--stage stage.py] [--phone-env '{"KEY":"1"}']
```

`--host` (default `gpu-wsl`) is the ssh destination of the machine running the computer,
`--host-env` the host's environment file there (for its owner token) and `--gpu-socket`
the broker's local socket in the computer (default the GPU acceptance seat's). `--stage`
is a Python script run on that machine with `python3 -` after the computer wakes, to
install a build before measuring. The driver bounds every step with a timeout, and on any
exit stops the phone app, the guest side and every process the guest launched, switches the present
trace off and removes its files from the computer. `--no-phone` runs the guest side on a
computer without launching the phone app, and `--no-wake` skips waking a computer that is
known to be awake.

Results: `<app>.json`, `summary.md`, `phone-console.log` and `guest-events.jsonl` (each
line prefixed with its arrival time on the Mac), and `guest/` with the guest's own
scorecards, pictures and each app's log.

## Run the guest side by hand

Inside a computer, as its owner:

```sh
python3 framelab-guest.py --out /tmp/framelab [--apps vkcube,terminal] [--offline] [--no-reference]
```

It prints one JSON event per line and writes the same files as the driver's `guest/`.

## Check it headless

```sh
cargo build --release -p caboose-display -p caboose-display-probe   # in guest/display
guest/framelab/check.sh IMAGE guest/display/target/release [OUT] [-- --apps vkcube,gtk4]
```

`IMAGE` is a computer image with the matrix's apps (see the comment in `check.sh`). The
check starts a private seat with caboose-display-probe as its client, runs the matrix
with local pages, and then measures vkcube against `standin-broker.py`, which writes the
real broker's present trace. It fails when an installed app shows no window or no frames,
when a compared app has no comparison, or when the stand-in's presents do not reach the
scorecard. Without a phone every app draws on the computer, so this checks the guest
side and the scoring, not the phone's rendering.

## Tests

```sh
python3 -m unittest guest/framelab/test_framelab.py
```
