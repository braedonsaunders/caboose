#!/bin/sh
# Display recovery and connection diagnostics, on a signed phone paired to a deployed host
# whose guest sends a hello epoch (caboose-display with `epoch` in its hello; an older guest
# reconnects but cannot keep windows, see step 9). Keep Computer settings > Display open on
# a second device or take screenshots: every figure there is measured on the phone.
set -eu
cat <<'CHECK'
Setup: add the host's VPN or public address in Computer settings > Remote Access, open two
Linux apps (a terminal and a browser), present the terminal as a card and show the keyboard.

1. Wi-Fi to cellular. Turn Wi-Fi off in Control Center while typing in the terminal.
   Within about 5 s the banner reads "Reconnecting" with "Input is paused"; the terminal's
   last picture stays and the keyboard stays up. Within about 15 s more it is connected
   over the remote address (Computer settings > Display: Address ends "(remote)", Network
   "Cellular"). The same card is still presented; typing reaches the same terminal.
2. Cellular to Wi-Fi. Turn Wi-Fi back on. A live connection over the VPN may stay where it
   is (Display shows no loss); if it stalls, it reconnects on the LAN within about 5 s.
3. No network. Turn on Airplane Mode. The banner reads "Waiting for a network" and the
   attempt count does not advance. Turn it off: one attempt starts at once and connects.
4. A dead link that stays open. On the host, block the phone's traffic without closing the
   socket (for example `sudo pfctl` or `iptables -I INPUT -s <phone> -j DROP` on the path
   to the relay). Within 15 s Display records "Nothing arrived from the computer for 15
   seconds." in Recent losses and the banner shows the retry schedule (0.5, 1, 2, 4, 8,
   15, 15, 15 s). Remove the block: the next attempt connects. After eight failures the tab
   shows Out of Reach; Try Again starts a new series.
5. Lock and unlock. Lock the phone for 30 s and unlock it. The windows come back with their
   cached pictures (same epoch), the presented card is unchanged.
6. External monitor. With the desktop on a USB-C monitor, unplug it while connected: the
   desktop returns to the phone without a reconnect (Display: no new loss). Plug it in
   during a reconnect (step 4): the resumed hello carries the monitor's size, and one
   connection opens per attempt (compositor log: one "session started" each; a "replaces"
   line may name only the phone's own dead connection, and the phone never shows On
   Another Device).
7. Monitor sleep. Let the monitor sleep with the desktop on it, wake it: the stream
   continues; Pictures per second rises again when it shows the desktop.
8. Another device. Open the display on a second device: the phone shows On Another
   Device and never reconnects on its own; Show Here takes it back.
9. Cold boot. Restart the computer from Computer settings, or restart caboose-display.
   The reconnect keeps nothing: windows from before are gone and new windows never show a
   stale picture. With an older guest that sends no epoch the same is true of every
   reconnect: the windows are removed and repainted by the new keyframes.
10. Diagnostics. While dragging a window and typing, Display shows Round trip, Receiving,
   Pictures, Decode and Waiting to decode with figures; Waiting to send stays near
   Nothing on Wi-Fi and grows on a throttled link (Settings > Developer > Network Link
   Conditioner, "Very Bad Network"). With no samples a figure shows a dash, never zero.
CHECK
