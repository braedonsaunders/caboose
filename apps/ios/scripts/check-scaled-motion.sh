#!/bin/sh
# Human-driven check on a signed iOS device and a real computer.
set -eu
cat <<'CHECK'
Pair a signed Caboose build on a device with MetalFX spatial scaling support to a
computer running this display build. In Chromium open a video with visible controls
and text around it. Keep it playing long enough for motion detection, then:
1. Resize, rotate, scroll the video partially off screen, and switch between a tile and
   its app card. Verify the image stays aligned and clipped to its player, with no black
   gaps, duplicate image, flicker, or frozen overlay.
2. Pause and resume, then close the video. Verify the last picture returns to the window
   and the rest of the page remains intact.
3. Repeat on a device without MetalFX spatial scaling. Verify the software-upscaled video
   remains visible and aligned through the same interactions.
Use guest/display/scripts/check.py scaled-motion on the host to verify the negotiated
bitstream dimensions and decode separately. Record device, OS, server build, and results.
CHECK
