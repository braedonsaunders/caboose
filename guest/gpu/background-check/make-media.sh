#!/bin/sh
# Writes clip.webm (VP9 video with an Opus tone, 20 s, looped by media.html) next to this script.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
ffmpeg -nostdin -hide_banner -loglevel error -y \
  -f lavfi -i testsrc2=size=1280x720:rate=30:duration=20 \
  -f lavfi -i sine=frequency=330:duration=20 \
  -c:v libvpx-vp9 -b:v 2M -deadline realtime -cpu-used 8 -g 60 \
  -c:a libopus -b:a 96k -shortest "$here/clip.webm"
