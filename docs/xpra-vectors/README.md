# Xpra capture research

These examples are **partial**, not a complete protocol conformance suite. They
were recorded from the real Xpra 6.5.5-r0-1 GTK client and seamless server on
Debian 13. `session.json` exercises window creation, a metadata update, WebP and RGB
draws, key input, and a clipboard request and response.
`png-session.json` is a PNG draw received by a small direct WebSocket test client
from a modern-mode server. `video-session.json` contains the first x264 H.264 draw from a synthetic
animated terminal with `XPRA_TEXT_USE_VIDEO=1`.

The capture included machine identifiers, process IDs and full hello dictionaries.
`extract.py` decodes it, keeps an allowlisted subset, and re-encodes each selected
packet with an uncompressed header. `sanitized_frame_hex` is consequently a
valid **re-encoding**, not the original wire bytes; raw chunks have been joined.
Binary packet values are represented as `{ "bytes_hex": "..." }` in JSON.
The unsanitized capture and server logs must not be committed.

To reproduce a similar capture on a Docker host with `/data/tmp` available:

```sh
cd docs/xpra-vectors
docker build -t caboose-xpra-vector-test .
workdir=$(mktemp -d /data/tmp/caboose-xpra-vector.XXXXXXXX)
docker run --rm -v "$PWD/capture.py:/capture.py:ro" -v "$workdir:/out" caboose-xpra-vector-test /usr/bin/python3 /capture.py
docker run --rm -v "$PWD/extract.py:/extract.py:ro" -v "$workdir:/out:ro" caboose-xpra-vector-test /usr/bin/python3 /extract.py /out/capture.json > "$workdir/sanitized.json"
```

To regenerate the modern PNG draw:

```sh
docker run --rm -v "$PWD/capture-png.py:/capture-png.py:ro" -v "$workdir:/out" caboose-xpra-vector-test /usr/bin/python3 /capture-png.py
```

This writes `png.json` to the temporary directory. The test starts xterm with
`sleep` so its pixels do not contain a shell prompt or machine name.

To regenerate the H.264 sample, use a separate empty temporary directory for
this run (the raw capture and logs include machine identifiers):

```sh
videodir=$(mktemp -d /data/tmp/caboose-xpra-video.XXXXXXXX)
docker run --rm -v "$PWD/capture-video.py:/capture.py:ro" -v "$videodir:/out" caboose-xpra-vector-test /usr/bin/python3 /capture.py
docker run --rm -v "$PWD:/vectors:ro" -v "$videodir:/out:ro" caboose-xpra-vector-test /usr/bin/python3 /vectors/extract-video.py /out/capture.json > "$videodir/video.json"
```

The test forces video encoding for the synthetic text animation; it is not a
recommendation for the guest's production encoding policy. Inspect the generated
JSON, including any image pixels, before publishing. The generated window IDs, timing,
metadata and encodings can differ. The test starts a disposable unauthenticated
server on container loopback; it does not exercise guest authentication or KVM.
The container is removed on exit, including its Xpra, Xvfb, xterm and xclock
processes. Keep the raw capture and log private and delete the temporary directory
when finished.
