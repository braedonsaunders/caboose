# GPU resize check

Checks that a Vulkan window's picture fills its window on the phone when the window
changes size: a fold or unfold, a rotation, Laptop and Tablet, a full-screen window
following the display. It runs on the computer as the display's user. Someone looks at
the phone, or takes screenshots, while it runs.

`resize_check.c` opens an X11 window and draws into it on the computer's Vulkan device
(the phone's GPU on the GPU seat) with a picture whose placement shows at a glance: red,
green, blue and yellow quadrants inside a white border, and a white bar moving across the
middle so presents keep arriving. It prints each swapchain it creates with the window's
size and the surface's extent limits, and each size the window is configured to.

| Option | Behaviour |
| --- | --- |
| `--size WxH` | The window's first size and, without a surface extent, the swapchain's (default 800x600) |
| `--follow` | Recreates the swapchain at the window's size on each configure, as a resizable application does |
| `--child` | Draws into a child window that follows its top-level, as Wine draws a Win32 window's client area |
| `--child-size WxH@S` | The child stops following and becomes WxH S seconds in: the application keeps its own resolution in a window that has since changed size, as a full-screen Wine game does after the display changes (implies `--child`) |
| `--fullscreen` | Asks for `_NET_WM_STATE_FULLSCREEN` before mapping |
| `--seconds S` | Runs this long, then exits (default 60) |

## Build and run

```sh
cc -O2 -std=c11 -D_POSIX_C_SOURCE=200809L resize_check.c -o resize-check -lvulkan -lxcb
set -a; . /run/caboose/display.env; set +a
./resize-check --child --size 1902x1338 --child-size 1000x700@10 --seconds 60
```

It needs the Vulkan and XCB headers to build, and the display's environment to run.

## What to see

The four quadrants and the whole white border are always visible, and the picture covers
the window: a full-screen window is filled; any other window is filled when the picture
has its shape and otherwise shows the whole picture scaled to fit, centred, with black
bars on two sides. The picture is never shown at an old size in a corner, cut off, or
replaced by black. After `--child-size`, the 1000x700 picture is scaled to the window.
