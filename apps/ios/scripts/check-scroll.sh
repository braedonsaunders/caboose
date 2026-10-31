#!/bin/sh
# Phone-owned scrolling on a signed iOS device and a real computer.
set -eu
cat <<'CHECK'
Launch Caboose with CABOOSE_SCROLL_PROFILE=1 (and CABOOSE_SCROLL_REPLAY=1 for the scripted
flicks), for example:
  xcrun devicectl device process launch --device <device> \
    --environment-variables '{"CABOOSE_SCROLL_PROFILE":"1","CABOOSE_SCROLL_REPLAY":"1"}' \
    com.braedonsaunders.caboose
Open a long page in Chromium (an X11 window drawn as video) as the only card and keep it
on screen. With the replay, the script plays after three seconds and runs for about 26 s;
without it, do the same by hand: a slow drag, a medium flick, a hard flick, a hard flick
back, and three quick flicks in a row.
1. The content moves with the first finger movement and stays under the finger; flicks
   coast with iOS momentum at 120 Hz. Toolbars and the address bar stay put.
2. Hard flicks show content, not blank bands, beyond their first frames. Repeated flicks
   accelerate without gaps. Lifting at rest leaves the app's own picture (a caret blinks,
   hover works) at exactly the position shown, with no jump.
3. Flick to the end of the page: the content bounces back from the end as on iOS, and a
   drag past the end resists.
4. A tap on coasting content stops it without clicking.
Copy Documents/scroll-profile.jsonl from the app container:
  xcrun devicectl device copy from --device <device> --domain-type appDataContainer \
    --domain-identifier com.braedonsaunders.caboose \
    --source Documents/scroll-profile.jsonl --destination scroll-profile.jsonl
Each line is one gesture: touch_to_glass_ms, frame_interval_ms, late_frames, blank,
pictures (moved/still/unrelated), app_latency_ms and app_gain. Record device, OS, server
build, the app and the lines.
CHECK
