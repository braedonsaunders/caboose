# guest/gpu/gfxstream/warmup

Fills a new executor session's capability cache (`../bounded-memory/static_query_cache.h`)
before applications ask, so the first GL or Vulkan start after the phone connects does not
pay one round trip per capability question.

- `caboose-gpu-warmup-session SOCKET` is run by the GPU broker, detached and at the lowest
  CPU priority, once a new executor session is serving on `SOCKET`. Nothing waits for it, and
  the broker ends it with the session. It sources the launch environment applications get
  (`$CABOOSE_LAUNCH_ENV`, default `/run/caboose/display.env`).
  - With logs from earlier sessions in `capabilities/history/` beside the socket, it runs
    `caboose-gpu-warmup --replay` on the newest four.
  - Without any, it starts the computer's GL implementation and each installed
    `org.freedesktop.Platform` runtime's once each. Their questions become the next
    session's history.
- `caboose-gpu-warmup` starts the GL implementation it runs under once, headless: EGL's
  surfaceless platform and a compatibility context made current without a surface. It
  loads only `libEGL.so.1` at run time, so the same binary runs inside a Flatpak runtime,
  where it is the copy in the "host" GL extension.
- `caboose-gpu-warmup --replay LOG...` reads the questions recorded in earlier sessions'
  logs, with checksummed records only: format, image-format and external-semaphore queries,
  physical-device properties (each chain rebuilt from the sTypes and sizes in its key),
  queue families and the device's extension list.
  Eight processes ask the new executor all of them, each taking a share; the executor
  answers separate processes side by side. Answers are never carried over from an earlier
  session, only which questions were asked. It asks only devices whose name appears in a
  log's identity, or every device when none matches. It reads only logs of processes of
  its own pointer width: a question's chain was laid out for that width, and its answers
  belong to that width's scope. Its line reports the width (`bits`), the questions asked,
  the logs of another width it left (`skipped_logs`) and `incomplete` when a process of it
  failed, with the reason before it.

The broker moves the previous sessions' logs into `capabilities/history/` when a session
starts, and keeps the newest four. An application that asks while the warm-up is still
asking joins the pending answer instead of asking again (single flight, in
`static_query_cache.h`).

## Build

```sh
cc -O2 -Wall -Wextra -Wno-missing-field-initializers -I VULKAN_HEADERS \
  -o caboose-gpu-warmup caboose-gpu-warmup.c -ldl
```

`VULKAN_HEADERS` is any Vulkan 1.3 header tree, such as the pinned Mesa checkout's `include/`.

## Install

| File | Path |
|---|---|
| `caboose-gpu-warmup` | `/usr/local/libexec/caboose-gpu/caboose-gpu-warmup` |
| `caboose-gpu-warmup` | `/var/lib/flatpak/extension/org.freedesktop.Platform.GL.host/x86_64/1.4/lib/caboose-gpu-warmup` |
| `caboose-gpu-warmup-session` | `/usr/local/libexec/caboose-gpu/caboose-gpu-warmup-session` |

The broker looks for `caboose-gpu-warmup-session` beside its own modules. When it is
absent, sessions start with an empty cache.

## Check

Run a GL start against a session that has just started, with diagnostics:

```sh
CABOOSE_CAPABILITY_CACHE_DIAGNOSTICS=1 caboose-gpu-warmup
```

The `CABOOSE_CAPABILITY_CACHE` line shows hits, misses, claims and joined answers. The
broker's log shows each warm-up's `CABOOSE_GPU_WARMUP` line.

`../driver/test.sh` builds and runs `test_warmup.c`, which checks that the replay reads
only logs of its own pointer width.

## Limitation

A GL start still makes the round trips the cache cannot cover: instance creation and
enumeration, its first physical-device properties query (which identifies the device),
features and memory properties (which the driver adjusts per process) and device creation.
A short-lived process that starts GL just before it exits still pays them.

The warm-up runs as a 64-bit process on the computer, so 32-bit applications' questions
(Steam's client is one) are not asked again: the first 32-bit process of a session asks
them, and later ones share its answers.
