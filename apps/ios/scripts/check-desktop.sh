#!/bin/sh
# Human-driven checks on a signed device and real computer.
set -eu
cat <<'CHECK'
Open Chromium, Thunar and a terminal on a signed device paired to a real computer.

Portrait/landscape shell (Tablet mode, no external display):
1. Keep the actual Desktop tab open with Chrome focused. Rotate the opened Duo
   landscape -> portrait -> landscape, with native rail on either side. Portrait
   has only a controls icon inside the far-right end of the dock: no full-height rail, top toolbar or
   system tabs. Landscape restores the existing controls. Repeat on iPad (Tiled
   and Free), including its system-tab configuration, and a closed portrait phone.
   Chrome uses the full available viewport with its tab/address bars intact; the
   dock remains at the bottom. No vacant strip remains where the rail was.
2. Open the portrait panel: it points to its button and grows upward, with controls
   and Home/Desktop/Agents/Apps/Terminal in one skinny vertical icon column. No square
   dashboard or detached floating trigger appears. It stays narrow on phone and iPad.
   Close it using Close, outside tap, and VoiceOver escape. Test large accessibility
   text and scrolling. Opening/closing it must not resize Chrome or move the dock.
   Try Keyboard, Screen Layout, AirPlay, Wallpaper, Computer, and lifecycle controls.
3. Show/hide the keyboard in portrait, then rotate with it shown. The portrait panel
   remains the chosen chrome despite the shortened viewport. Controls stay reachable
   and the dock clears the keyboard. Dismiss it: the full viewport returns without drift.
4. Visit Home/Apps and return; no duplicate tab bar appears. Enter/leave browser
   fullscreen and the existing app card; controls and dock return once. Rotate with
   the panel open. In Laptop mode verify the accepted upper app and lower controls
   remain intact with no extra portrait button, then return to Tablet and repeat.

Switchyard (Desktop tab, no external display):
1. On a closed/upright phone, move between columns using the dock. Open the Duo or
   rotate a large phone: two columns fit; an iPad offers thirds. Drag a gap and
   stack two tiles. The complete Chrome tab strip, address bar and refresh button
   remain visible during resizing and after it settles. Thunar fits its tile.
2. Double-tap the grabber: the same full-screen app card as Apps opens, with its
   window menu, keyboard and close controls. Focus a different tile, then use the
   landscape toolbar's Full Screen control: that app opens directly.
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
   on exit. Use the covering window's top tab to exit, then enter it again.
   In the app card reveal native controls from the sidebar edge and choose
   Window Options -> Exit App Full Screen. Browser controls return; the complete
   picture stays within the viewport. Repeat with page/player fullscreen and a
   different fullscreen app (a slideshow or game), including hardware Escape.
   Exit App Full Screen remains offered even before fullscreen metadata arrives.
   After pulling back to a tile, another app can enter full screen.
   Play a video in a tile, then open that same app as a card and return repeatedly.
   Resize/fold/rotate during playback: video stays registered over the base picture,
   without a second moving image at the borders or video bleeding beyond the window.
   Scroll the player partially out of view: clipping does not rescale its picture.
6. Open a card from Apps and Home on the Duo, closed/open and rotated, with the
   sidebar on either side. Back, Switch App, Keyboard and Window Options are in
   the side toolbar; no window title or custom controls row takes app height.
   The app fills the height beside the bar, with no content under either side's
   safe area. Switch App lists the current title and every open app; select one,
   then edge-swipe back. Back returns to the originating tab without closing Linux.
   Desktop's trailing Full Screen control opens the focused app card directly.
   On Duo the card starts with controls hidden; swipe inward from the sidebar edge
   to reveal them, then use Hide Sidebar or swipe outward on its controls to hide.
   Card Full Screen is also in Window Options. Collapse the sidebar
   until toolbar actions overflow; open Full Screen, Switch App and Window Options:
   their system dialogs point to the button that opened them, beside the sidebar,
   with every action reachable and no clipped or near-zero-height submenu. They
   must not point at the middle of the app. Repeat with the keyboard open.
   On an ordinary iPhone, repeat upright and landscape with large accessibility
   text: the compact horizontal toolbar and all four icon controls stay usable,
   clear of the sensor housing, home indicator and app content.
   Show/hide the keyboard and rotate/fold: the whole app fits above the keyboard
   and accessory row, and Hide Keyboard remains reachable. In Window Options,
   check Ask Agent About This Window (when available), Redraw and Close Window.
   Enter Full Screen: native controls disappear and the viewport grows. Reveal them
   with the inward edge swipe (or the top handle); this preserves guest fullscreen.
   Exit App Full Screen is a separate action. VoiceOver can activate Show window controls,
   Back, Switch App, Keyboard and Window Options. Open a dialog and a submenu in
   both modes: they fit and accept input. Dismiss the card: Desktop fits again.
   On iPhone and iPad, open a spreadsheet as a card from Apps and from a tile.
   Double-tap a cell into editing: the keyboard opens from the guest's editing
   signal. Leave editing by tapping noneditable content: it closes. Hide it manually
   and wait: it stays hidden until another editing tap. Return retains existing
   dismissal behavior. Double-tap noneditable browser content to select/zoom:
   the keyboard stays closed. Repeat with native Wayland and pointer-routed Xwayland.
7. Switch Desktop -> Home -> Desktop. Columns retain their positions. Open an app
   from Apps: it opens as a card and edge-swiping moves to the next app.
   On Home, scroll Open, Pinned and Recent all the way right in every folded and
   rotated/sidebar state: live previews and icons stay inside the content column.
   Long Recent Files names/paths truncate inside the same column.

External display, then iPad Desktop set to Free:
   Connect a USB-C monitor before launch and while the app is open. Its external
   scene shows Desktop automatically and the phone shows the trackpad, without
   selecting an AirPlay route. Disconnect and reconnect; the device desktop and
   app cards still own their geometry correctly. Repeat with AirPlay, and resize
   the external scene if supported. Verify window placement and input each time.
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
    With the sidebar on either side, verify the shared accessory spans the keyboard,
    its controls remain in two horizontal rows and all keys scroll into view. Check
    Terminal, an app card and Desktop, including folded and rotated layouts.
    Open All Apps from the desktop dock and from an empty desktop; both grids show
    the same apps, scroll to the end and open a selection. Close the overlay with
    its close button and by tapping outside it.
   On the external desktop, open Launchpad with more apps than fit on one page;
   use the trackpad and pointer to move forward and back, and open an app on the
   final page. Close and reopen it, then repeat after changing the display size.

Shared keyboard accessory:
12. In app cards, tiled/free Desktop, external-display trackpad and Terminal on
    iPhone, Duo outer/inner displays and iPad, show the keyboard. Hide Keyboard
    is always above the key row at the right, never in the ellipsis menu. Scroll
    the key row: Hide stays visible. Hide, reopen, fold and rotate; content fits
    above both rows. Ctrl/Alt modify one subsequent key, arrows repeat while held,
    Escape/Tab/navigation work, and Return submits/dismisses outside code apps.
    In remote apps verify Aa, QuickPath and marked-text composition; in Terminal
    verify application-cursor arrows and explicit ANSI backgrounds still work.

Desktop touch and close controls:
13. Open Files on a tiled Duo and an iPad Free desktop. Two quick taps on a folder
    open it once. A single tap selects once. Hold an item: its context menu appears
    before lifting, at that item, and lifting does not choose a menu action. Small
    finger jitter must not drag; moving away before the hold cancels context.
    Tap then hold and move performs a primary drag. Native app pinch still works.
14. Hold a dock app icon: Open, Pin/Unpin and its Close Window actions appear. Open
    focuses its existing desktop window. GridCraft and other tiles have a visible
    top-right Close Window button; closing still permits the app's unsaved-work dialog.

Capture evidence with:
  xcrun devicectl device info displays --device DEVICE
  xcrun devicectl device capture screenshot --device DEVICE --destination shot.png
Use --display-unique-id from the first command to capture each available display.
Record which device/orientation/display and checks passed; a build alone is not a pass.
CHECK
