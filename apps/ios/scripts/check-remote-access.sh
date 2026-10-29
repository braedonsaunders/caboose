#!/bin/sh
# Run with a signed app and a paired phone; use addresses of the same host.
set -eu
cat <<'CHECK'
1. Pair on Wi-Fi and verify the computer and Files work.
2. Open Computer settings > Remote Access. Add the host's reachable VPN URL.
3. Disable Wi-Fi, keep the VPN connected, and wake the computer. Verify display and Files.
4. Return to Wi-Fi, remove the alternate, and wake again. Verify the original connection works.
5. With the host unavailable, open Computer settings and add the VPN URL; verify reconnect.
6. Verify the phone remains listed in the console and Files retains its existing domain.
CHECK
