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
   window menu, keyboard and close controls. Focus a different tile, then use the
   right-side toolbar's Full Screen control -> Open App Full Screen: that app opens.
   There is no separate Full Screen button centered above the tile. Repeat with
   the grabber menu, VoiceOver Full Screen action and Command-Option-F.
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
6. Open a card from Apps and Home on the Duo, closed/open and rotated, with the
   sidebar on either side. Back, Switch App, Keyboard and Window Options are in
   the side toolbar; no window title or custom controls row takes app height.
   The app fills the height beside the bar, with no content under either side's
   safe area. Switch App lists the current title and every open app; select one,
   then edge-swipe back. Back returns to the originating tab without closing Linux.
   From Desktop's trailing Full Screen control, Hide Desktop Bars expands the whole
   desktop; its handle restores the sidebar. Card Full Screen is in the trailing
   Window Options actions, never a centered floating button. Collapse the sidebar
   until toolbar actions overflow; open Full Screen, Switch App and Window Options:
   their system dialogs escape the sidebar group, with every action reachable and
   no clipped or near-zero-height submenu. Repeat with the keyboard open.
   On an ordinary iPhone, repeat upright and landscape with large accessibility
   text: the compact horizontal toolbar and all four icon controls stay usable,
   clear of the sensor housing, home indicator and app content.
   Show/hide the keyboard and rotate/fold: the whole app fits above the keyboard
   and accessory row, and Hide Keyboard remains reachable. In Window Options,
   check Ask Agent About This Window (when available), Redraw and Close Window.
   Enter Full Screen: controls disappear and the viewport grows. Tap or pull its
   top handle to restore controls; VoiceOver can activate Show window controls,
   Back, Switch App, Keyboard and Window Options. Open a dialog and a submenu in
   both modes: they fit and accept input. Dismiss the card: Desktop fits again.
7. Switch Desktop -> Home -> Desktop. Columns retain their positions. Open an app
   from Apps: it opens as a card and edge-swiping moves to the next app.
   On Home, scroll Open, Pinned and Recent all the way right in every folded and
   rotated/sidebar state: live previews and icons stay inside the content column.
   Long Recent Files names/paths truncate inside the same column.

External display, then iPad Desktop set to Free:
8. Use the green title-bar button to maximize Chromium. The title bar meets the
   top edge; left/right edges fill the desktop; the bottom clears the dock.
   The address bar, refresh button and window buttons remain visible. Restore:
   the previous size/position returns. Repeat with a second Chrome window.
9. Resize/rotate the display and change UI scale while maximized: the window
   still fits above the dock. Drag/resize it manually, then maximize and restore:
   it returns to that new manual frame.
10. Use F11 in Chromium: browser full screen covers the display and hides the dock.
   Use F11 again: all browser and window controls return. Repeat after maximizing.

Native Terminal tab:
11. On a Duo with a vertical sidebar, open Terminal: the grid reaches the top,
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
