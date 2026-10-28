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
2. Double-tap the grabber: the same full-screen app card as Apps opens, with its
   window menu, keyboard and close controls. Repeat with the visible Full Screen
   button, grabber menu, VoiceOver Full Screen action and Command-Option-F.
   Double-tap browser content: the browser receives it. Drag the grabber and long
   press it: carrying and its menu still work. Close the card: Desktop remains
   selected and its tile layout returns, without an amber border around Chrome.
   Fold/unfold the Duo and rotate an ordinary phone both in the card and after
   dismissing it. Hide/show card controls and desktop bars. In each state Chrome
   uses the available viewport, keeps its tab strip/address bar/refresh button,
   and never runs beneath the sidebar. Switch tabs and move the sidebar too.
3. In both tiled and full-screen views, open a browser menu, context menu and
   file chooser. Each appears above its parent and accepts input. Close the
   app card and check that the bars/dock return and another tile works.
   Fit a minimum-width window into a narrow tile, then open a menu and submenu:
   they stay attached to their controls. Leave a dialog open, switch to another
   column, and open that column as a card: the previous column's dialog does not follow.
4. Two-finger tap in Chromium (native Wayland) and Thunar (Xwayland): one context
   menu opens at the touch with a ring and haptic. A two-finger pinch or moving
   fingers must not open a menu. Long-press in Thunar also right-clicks.
5. Enter and leave the browser's own full screen (F11). Browser chrome returns
   on exit. After pulling back to a tile, another app can enter full screen.
6. Switch Desktop -> Home -> Desktop. Columns retain their positions. Open an app
   from Apps: it opens as a card and edge-swiping moves to the next app.
   On Home, scroll Open, Pinned and Recent all the way right in every folded and
   rotated/sidebar state: live previews and icons stay inside the content column.
   Long Recent Files names/paths truncate inside the same column.

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

Native Terminal tab:
10. On a Duo with a vertical sidebar, open Terminal: the grid reaches the top,
    bottom and outer edge beside the sidebar, without a Terminal title strip.
    Open the keyboard: the grid ends above its accessory keys. Hide it: the grid
    fills the height again. Repeat unfolded and rotated; the session menu stays
    accessible. On devices with horizontal bars, the grid stays between the bars.

Capture evidence with:
  xcrun devicectl device info displays --device DEVICE
  xcrun devicectl device capture screenshot --device DEVICE --destination shot.png
Use --display-unique-id from the first command to capture each available display.
Record which device/orientation/display and checks passed; a build alone is not a pass.
CHECK
