#!/bin/sh
# Encodes the AV1 and VP9 fixtures tests/media_videotoolbox_test.mm decodes (it encodes its
# H.264 and HEVC streams itself), with FFmpeg's reference decodes beside them:
#   sh tests/media_fixtures.sh DIR
# AV1 is a low-overhead OBU stream (one temporal unit per picture, as the guest driver sends
# it); VP9 is IVF (one frame or superframe each, with hidden alt-ref frames). Needs ffmpeg
# with libsvtav1 and libvpx-vp9.
set -eu
out=${1:?output directory}
mkdir -p "$out"
src="-f lavfi -i testsrc2=size=640x360:rate=30 -frames:v 30"
ffmpeg -loglevel error -y $src -pix_fmt yuv420p -c:v libsvtav1 -g 10 -f obu "$out/av1-8bit.obu"
ffmpeg -loglevel error -y $src -pix_fmt yuv420p10le -c:v libsvtav1 -g 10 -f obu "$out/av1-10bit.obu"
ffmpeg -loglevel error -y $src -pix_fmt yuv420p -c:v libvpx-vp9 -g 10 -auto-alt-ref 1 -lag-in-frames 16 -b:v 2M "$out/vp9-profile0.ivf"
ffmpeg -loglevel error -y $src -pix_fmt yuv420p10le -c:v libvpx-vp9 -profile:v 2 -g 10 -auto-alt-ref 1 -lag-in-frames 16 -b:v 2M "$out/vp9-profile2.ivf"
for f in av1-8bit av1-10bit vp9-profile0 vp9-profile2; do
  in=$(ls "$out/$f".*)
  case $f in *10bit|*profile2) fmt=p010le ;; *) fmt=nv12 ;; esac
  ffmpeg -loglevel error -y -i "$in" -f rawvideo -pix_fmt $fmt "$out/$f.yuv"
done
echo "fixtures in $out"
