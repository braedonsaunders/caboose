#!/bin/sh
set -eu
cat <<'CHECK'
Laptop layout — signed app on the paired physical Duo:
1. Open Desktop and a browser plus a file manager. Screen Layout -> Automatic.
   Open the phone flat: ordinary tablet desktop. Fold it into a tabletop position,
   with the hinge horizontal: the desktop is above the fold, trackpad below. Move
   the hinge slightly: no repeated layout toggles. Rotate into a vertical book
   fold: ordinary layout. Close the phone: compact desktop with no lower panel.
2. Choose Screen Layout -> Laptop while flat. It splits without requiring a fold.
   Choose Tablet while folded: it stays tablet. Restore Automatic. Repeat in an
   app card opened from Apps. In Laptop Desktop, opening a window keeps the same
   workspace: no Full Screen button or Exit App Full Screen menu item, no duplicate
   card controls. In Tablet, the green button still opens the native app card.
3. Tablet: check the full title bar and whole dock, with no top/bottom clipping.
   Laptop: no system sidebar or toolbar spans the upper half. All shell controls
   stay in the lower-right rail. The app fills the upper viewport without Caboose
   title bars; the dock is at the top of the LOWER half.
   Choose Keyboard, Trackpad and Combo from the input button. Only one keyboard
   header is shown, with no scrolling or glass key rows; Hide stays at its right.
   In the lower trackpad move the pointer to an address bar, click and type.
   The SAME shared keyboard/accessory opens, Hide Keyboard is at its top right,
   and the whole upper app remains above the keyboard. Hide it: trackpad returns
   and stays visible. Repeat typing/Hide/Return, IME composition, cell double-click
   in a spreadsheet, and switching the focused window. No focus oscillation.
   Combo: the full-width trackpad occupies roughly the upper third of the lower
   panel. The full-width custom keyboard is below it, with an attached opaque header
   and Hide at its top right. No native keyboard appears. Type, Shift/caps lock,
   symbols, held Delete, arrows and Ctrl shortcuts; use the globe for native IME.
4. Move from the app across the hinge into the lower dock. Open an app from its dock
   icon, right-click it, and use Close; the cursor and click must agree everywhere.
   Two-finger tap opens a context menu; scroll with two fingers. Tap then drag
   a selection, and background or switch the target while dragging: no stuck
   mouse button when returning. Click a dialog; keyboard goes to that dialog.
   Check visible pointer/click alignment in minimum-size apps and popups.
   Pinch to zoom in/out in an app supporting Ctrl+Plus/Minus; ordinary two-finger
   scrolling must not zoom. Drag with three fingers; lift one or interrupt with
   backgrounding: release immediately, no stray click. Four-finger left/right
   switches windows once per swipe; up opens the chooser, down dismisses it.
   Repeat on the external-display trackpad, including staggered finger arrivals.
5. Connect a USB-C monitor (or AirPlay). Laptop mode shows a phone window overview
   above its control pad. Select a window there: it focuses on the monitor without
   moving/resizing the monitor's windows or losing video. Type, scroll, right-click,
   drag, disconnect the monitor and continue on the phone. Repeat opened/flat.
6. Check VoiceOver labels for Screen Layout, Switch Window, Type and Hide Keyboard;
   large text; native sidebar reveal/hide; hardware keyboard; fold/rotate during
   reconnect. Leaving Laptop mode preserves the app and restores the full viewport.
CHECK
