# Background media check

Checks that media playing in Chromium on the computer survives the phone app going to
the background and coming back. Video and sound keep playing, the page is not reloaded,
Chromium's GPU process moves off the phone and back, and frames reach the phone again
afterwards. It runs on the computer, against the Chromium the phone is showing. Someone
or something (the phone test driver) backgrounds and foregrounds the app while it runs.

| File | What |
| --- | --- |
| `media.html` | Fixture page: a looping VP9 + Opus video, a Web Audio tone and a frame counter that repaints every frame |
| `make-media.sh` | Writes `clip.webm` (20 s, generated with `ffmpeg`: `libvpx-vp9`, `libopus`) |
| `watch.py` | Opens the fixture in a new tab over CDP, starts playback with a CDP click, samples the page and Chromium's GPU process every 250 ms, and prints a JSON verdict |
| `test_watch.py` | Unit tests for the verdict |

## Run

```sh
./make-media.sh
python3 watch.py --cdp http://127.0.0.1:9222 --seconds 120 --expect-gpu-restarts 2 \
    --broker-log /path/to/caboose-gpu-broker.log --out timeline.jsonl
```

Once it prints `watching`, wait about 20 s, send the phone app to the background, wait
about 30 s, and bring it back. Chromium must have its remote debugging port open on
`--cdp`. The page is served from a loopback port the script opens; nothing is fetched
from the network. `timeline.jsonl` holds every sample.

`--expect-gpu-restarts 2` expects the GPU process to restart when the phone's executor
leaves (Chromium moves to lavapipe) and again when it returns (the executor switch layer
in `../executor-switch` moves it back). `--broker-log` is the broker's standard error with
`CABOOSE_PRIVATE_GPU_PROGRESS=1`. The check requires presents there after the last GPU
process change, which shows Chromium is drawing on the phone again.

The verdict fails if:

- the page reloads (`performance.timeOrigin` changes);
- the video pauses, ends or errors, or stands still for more than 1 s;
- the audio context leaves `running`, or its clock stands still for more than 0.5 s;
- no frame is painted for more than 1 s;
- fewer GPU process restarts than expected are seen;
- no video frame is decoded after the last GPU process change;
- with `--broker-log`, the broker logs no presents after that change.

## Tests

```sh
python3 -m unittest discover -s guest/gpu/background-check
```
