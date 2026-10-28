#!/bin/sh
# Regenerates the media embedded in the golden vectors. Run in the dev container:
#   guest/display/scripts/dev.sh vectors/media/generate.sh
# The outputs are committed; regenerating changes their bytes (encoder versions differ),
# after which the write-vectors example must be re-run.
set -eu
cd "$(dirname "$0")"
src='testsrc2=size=64x64:rate=30:duration=1'
ffmpeg -loglevel error -y -f lavfi -i "$src" -frames:v 1 -pix_fmt yuv420p \
  -c:v libx264 -preset veryfast -profile:v high -x264-params keyint=1:bframes=0 \
  -bsf:v h264_mp4toannexb -f h264 keyframe-64x64.h264
ffmpeg -loglevel error -y -f lavfi -i "$src" -frames:v 1 -pix_fmt yuv420p \
  -c:v libx265 -preset veryfast -x265-params log-level=none:keyint=1:bframes=0 \
  -f hevc keyframe-64x64.hevc
ffmpeg -loglevel error -y -f lavfi -i 'testsrc2=size=16x16,format=rgba' -frames:v 1 \
  -update 1 icon-16x16.png
# One raw 20 ms stereo Opus packet: encoded into Ogg, then the first audio packet (after
# OpusHead and OpusTags) is taken out of the pages.
tmp=$(mktemp -d)
ffmpeg -loglevel error -y -f lavfi -i 'sine=frequency=440:sample_rate=48000' -ac 2 -c:a libopus -b:a 128k \
  -frame_duration 20 -t 0.1 "$tmp/tone.ogg"
python3 - "$tmp/tone.ogg" opus-stereo-20ms.opus <<'PY'
import sys
data, packets, current, i = open(sys.argv[1], "rb").read(), [], b"", 0
while i < len(data):
    assert data[i:i + 4] == b"OggS"
    lacing = data[i + 27:i + 27 + data[i + 26]]
    body = i + 27 + len(lacing)
    for n in lacing:
        current += data[body:body + n]
        body += n
        if n < 255:
            packets.append(current)
            current = b""
    i = body
open(sys.argv[2], "wb").write(packets[2])
PY
rm -rf "$tmp"
ls -l keyframe-64x64.h264 keyframe-64x64.hevc icon-16x16.png opus-stereo-20ms.opus
