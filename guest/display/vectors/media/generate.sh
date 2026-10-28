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
ls -l keyframe-64x64.h264 keyframe-64x64.hevc icon-16x16.png
