#!/bin/sh
# Human-driven checks on a signed device and real computer.
set -eu
cat <<'CHECK'
Open Chromium, Thunar and a terminal on a signed device paired to a real computer.

Switchyard (Desktop tab, no external display):
1. On a closed/upright phone, move between columns using the dock. Open the Duo or
   rotate a large phone: two columns fit; an iPad offers thirds. Drag a gap and
   stack two tiles. The complete Chrome tab strip, address bar and refresh button
   remain visible during resizing and after it settles. Thunar fits its tile.
2. Double-tap the grabber: the window fills the display without bars or dock.
   Pull the top tab down a little and release: it springs back. Pull farther:
   it returns to its tile. Tap the tab to exit too. Repeat using Command-Option-F.
3. In both tiled and full-screen views, open a browser menu, context menu and
   file chooser. Each appears above its parent and accepts input. Close the
   full-screen window and check that the bars/dock return and another tile works.
4. Two-finger tap in Chromium (native Wayland) and Thunar (Xwayland): one context
   menu opens at the touch with a ring and haptic. A two-finger pinch or moving
   fingers must not open a menu. Long-press in Thunar also right-clicks.
5. Enter and leave the browser's own full screen (F11). Browser chrome returns
   on exit. After pulling back to a tile, another app can enter full screen.
6. Switch Desktop -> Home -> Desktop. Columns retain their positions. Open an app
   from Apps: it opens as a card and edge-swiping moves to the next app.

External display, then iPad Desktop set to Free:
7. Use the green title-bar button to maximize Chromium. The title bar meets the
   top edge; left/right edges fill the desktop; the bottom clears the dock.
   The address bar, refresh button and window buttons remain visible. Restore:
   the previous size/position returns. Repeat with a second Chrome window.
8. Resize/rotate the display and change UI scale while maximized: the window
   still fits above the dock. Drag/resize it manually, then maximize and restore:
   it returns to that new manual frame.
9. Use F11 in Chromium: browser full screen covers the display and hides the dock.
   Use F11 again: all browser and window controls return. Repeat after maximizing.

Capture evidence with:
  xcrun devicectl device info displays --device DEVICE
  xcrun devicectl device capture screenshot --device DEVICE --destination shot.png
Use --display-unique-id from the first command to capture each available display.
Record which device/orientation/display and checks passed; a build alone is not a pass.
CHECK
