# Unbuffered Wayland fixture

`unbuffered_fixture.c` creates a real xdg toplevel and never attaches a
`wl_buffer`. It prints the Wayland surface object ID and each acknowledged
configure, including the suggested logical width and height. It does not itself
open a GPU stream or verify display-protocol window announcements.

With the Wayland client development files and `wayland-scanner` installed, build
in a private directory using the system's xdg-shell protocol XML:

```sh
wayland-scanner client-header /usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml xdg-shell-client-protocol.h
wayland-scanner private-code /usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml xdg-shell-protocol.c
cc -std=c11 -Wall -Wextra -I. /path/to/unbuffered_fixture.c xdg-shell-protocol.c $(pkg-config --cflags --libs wayland-client) -o unbuffered-fixture
WAYLAND_DISPLAY=wayland-0 ./unbuffered-fixture
```

An announcement check must associate the GPU stream and the Wayland surface
with the same process and observe `WindowCreate` on the authenticated owner
display connection. The client output alone does not establish that behavior.
