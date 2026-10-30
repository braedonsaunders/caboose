# Unbuffered Wayland fixture

`unbuffered_fixture.c` creates a real xdg toplevel and never attaches a
`wl_buffer`. It prints the Wayland surface object ID and each acknowledged
configure, including the suggested logical width and height. Optional stream
and surface socket arguments open the private v3 GPU stream and request a
zero-extent surface bind from the same process. The third argument is a real
boxed instance supplied by the test executor. A successful bind prints the
compositor window ID and surface generation.

With the Wayland client development files and `wayland-scanner` installed, build
in a private directory using the system's xdg-shell protocol XML:

```sh
wayland-scanner client-header /usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml xdg-shell-client-protocol.h
wayland-scanner private-code /usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml xdg-shell-protocol.c
cc -std=c11 -Wall -Wextra -I. /path/to/unbuffered_fixture.c xdg-shell-protocol.c $(pkg-config --cflags --libs wayland-client) -o unbuffered-fixture
WAYLAND_DISPLAY=wayland-0 ./unbuffered-fixture
# For a supervised private v3 test with an existing boxed instance:
WAYLAND_DISPLAY=wayland-0 ./unbuffered-fixture /private/stream.sock /private/surface.sock 123
```

An announcement check must observe `WindowCreate` on the authenticated owner
display connection and match its window ID to `BOUND`. The client output alone
does not establish that behavior.
