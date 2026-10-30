#!/bin/sh
# Human-driven checks on a signed device and real computer.
set -eu
cat <<'CHECK'
Open Chromium, Thunar and a terminal on a signed device paired to a real computer.

Native container corners (iOS 26 and 27, iPhone/iPad/external display):
1. In Tablet/Tiled, put one window across the workspace. Its straight top and left
   edges meet the workspace with no wallpaper strip. Scroll to the last column:
   its trailing edge is flush. Two/three columns and stacked tiles retain resize gaps.
2. Check the physical corner as well as the screenshot. Close/Full Screen/menu
   controls remain completely visible and tappable. Repeat Free mode maximized,
   restored, snapped and dragged near each corner. Pointer hit targets match controls.
3. Rotate/fold, move the sidebar, show the keyboard, and use iPad window resizing.
   Check Home cards, Agents panels, Terminal controls, trackpad, dock and sheets:
   boundary corners follow their container; interior cards retain their design radius.
4. Verify app-card fullscreen aspect, popup/input alignment, hinge division and DPI
   are unchanged. Repeat with VoiceOver and large text. No device radius is inferred
   from a safe-area height. Record device/OS/mode and before/after screenshots.

Switchyard snap chooser (Tablet Desktop tab, Tiled, no external display):
1. Open four ordinary windows. Drag the full-width tile's title from near its left,
   center and right ends. The small carried picture retains the grab position, and
   the chooser is visible above stationary windows but below the carried window.
   Select each half, quarter, third and
   complementary two-thirds region. The highlighted destination must equal the
   released tile, including title bar and interior resize gaps.
2. Start after scrolling several columns right. Hover the two repeated left-third
   choices: only the actual region is highlighted; its companions form the depicted
   three-column or two-column layout on release. Unchosen windows remain on the track.
3. Enter application fullscreen, then carry from its top pull-tab. Hover, change
   choices and cancel by leaving Desktop or backgrounding. Fullscreen and original
   layout return; repeat with rotation and reconnect. A valid drop exits fullscreen
   only at release. Observe configure traffic: hovering sends no geometry requests.
4. Release over a disabled region, palette gap, or outside the workspace: no layout
   change. Close a participant during the drag: the stale proposal cannot commit.
   Repeat with one, two and three windows: every fitting quarter remains selectable,
   empty slots stay vacant and no fake dock/Overview windows appear. With a 1024x640
   minimum-size window, every slot remains selectable: Linux keeps valid content size
   and the complete picture fits the slot. Check controls at the center and corners
   for matching input coordinates. Repeat in portrait and landscape, selecting every
   visible region from its center and just inside each border; no target sticks on Full.
5. Move outside the chooser onto another tile's upper/lower quarter, middle and
   outer fifth. Stack, swap and column previews remain visible above opaque tiles;
   edge scrolling and the final scroll position agree with the preview.
6. Repeat with pointer, touch and Reduce Motion. Verify existing VoiceOver title/menu
   width and fullscreen actions. Verify content scroll, fullscreen input alignment,
   native corner controls and the black Laptop hinge with no new input interception.

Floating desktop snap chooser (iPad Free/Tablet and external display):
1. Drag an app by its title bar beyond twelve points. A translucent chooser appears
   above the windows. Sweep across full screen, halves, all four quarters, thirds,
   and both two-thirds/one-third layouts. The preview matches the selected region.
2. Release on each region. Check the resulting window bounds and app controls.
   Place three windows into thirds and two into complementary two-thirds/one-third
   regions: they meet without gaps or overlap. Pull them out to restore free sizing.
3. Move out of the chooser and release in the desktop interior: no snap. Move to
   an edge: existing half/corner/maximize snapping works. A minimum-size app cannot
   select a dimmed destination. Dragging content or a resize corner shows no chooser.
4. Repeat by touch and trackpad, with Reduce Motion, after rotation and relaunch.
   Release or leave Desktop during a drag: no chooser remains on the next visit.

Monitor/window/presentation contract (record results; this script does not claim a pass):
1. Record xrandr --current and xdpyinfo for the owner display. Show/hide the keyboard,
   open/close app cards: monitor dimensions/DPI stay unchanged while ordinary windows
   reflow. Rotate Tablet portrait -> landscape -> Laptop -> Tablet: monitor dimensions
   follow the physical window or upper panel, never an old square or keyboard-shortened
   viewport. DPI and render scale stay as selected. Repeat with a saved old square mode,
   and while connecting/disconnecting an external display (external dimensions win).
2. Use a fixed-size dialog and a window with declared minimum/maximum hints; check
   xprop WM_NORMAL_HINTS on X11. Narrow the viewport: requests respect the hints, the
   committed picture fits without cropping, and menu/submenu targets stay aligned.
3. Enter application fullscreen. Keyboard changes leave its monitor size stable;
   fold/rotation transitions reconfigure the output and fullscreen surface to the measured
   physical mode. Check center/corners by touch and desktop trackpad, including
   a nested menu. Letterboxing does not activate the app or hidden desktop items.
   A scroll fling stops when the shown/committed geometry changes. A captured drag
   still releases on its original target. Exit explicitly and verify ordinary fitting.
4. Record an explicit monitor/DPI change separately. Wine assertions or misplaced input
   fail this check; policy unit tests do not establish live Wine/device compatibility.

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
0. Use a resizable app whose minimum width exceeds a portrait tile. Record its size
   hints and committed geometry. Its requested height grows with the required width,
   and after redraw the complete picture fills the tile without a large empty lower
   region. Repeat in an app card and a permitted desktop snap. Check corner taps,
   scrolling, menus and drops against the same picture. A genuinely fixed-size dialog
   keeps its aspect and may retain padding; it must not be stretched or cropped.
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
    A one-finger drag in a mouse-only window performs a primary drag. Native app pinch still works.
14. Hold a dock app icon: Open, Pin/Unpin and its Close Window actions appear. Open
    focuses its existing desktop window. GridCraft and other tiles have a visible
    top-right Close Window button; closing still permits the app's unsaved-work dialog.

Capture evidence with:
  xcrun devicectl device info displays --device DEVICE
  xcrun devicectl device capture screenshot --device DEVICE --destination shot.png
Use --display-unique-id from the first command to capture each available display.
Record which device/orientation/display and checks passed; a build alone is not a pass.
CHECK

cat <<'CHECK'
Direct touch on mouse-only windows:
- In an X11 paint app, select a paintable layer and draw with one finger: a continuous
  stroke begins at the contact point. In a text editor, drag to select; in a file manager,
  drag an item. None of these one-finger drags scrolls the app.
- Two fingers scroll with momentum; a two-finger tap or stationary hold opens context.
- During a drag add a second finger, background the app, or close the card: the primary
  button releases and later touches do not continue the old drag.
- Native Wayland browser swipes, canvas gestures, sliders and pinch remain native.
  With a hardware mouse/trackpad, primary drag and precise scrolling still work.
CHECK
