# guest/gpu

The computer side of the live GPU path ([docs/gpu-live.md](../../docs/gpu-live.md)): the
phone is the computer's GPU. Applications on the owner's seat load the phone's Vulkan driver,
whose calls the GPU broker carries to the phone, and their windows are presented from images
that live on the phone ([docs/gpu-buffers.md](../../docs/gpu-buffers.md)).

| Path | What |
| --- | --- |
| `install.sh` | Installs the live GPU broker and, where present, the driver and its layers (runs `install-live.py`) |
| `install-live.py`, `test_install_live.py` | Installs the live GPU broker, with `--driver` the phone's Vulkan driver, with `--executor-switch` and `--routing-layer` its layers, each 64-bit or i386 by the library ([docs/gpu-live.md](../../docs/gpu-live.md#applications)); its unit tests |
| `caboose-gpu-broker-launcher` | Runs the installed private broker modules |
| `broker/` | The broker's transport and the live wire formats, with golden vectors ([README](broker/README.md)) |
| `gfxstream/` | The phone's Vulkan driver (gfxstream's guest encoder) and its checks ([README](gfxstream/README.md)) |
| `gbm/` | The GBM backend for the computer's render node ([README](gbm/README.md)) |
| `routing-layer/` | Implicit Vulkan layer that lists the phone's GPU first and settles device-loss policy ([README](routing-layer/README.md)) |
| `executor-switch/` | Implicit Vulkan layer that moves applications from lavapipe back onto the phone's GPU when its executor returns ([README](executor-switch/README.md)) |
| `check-apps.sh`, `socket-recorder.py` | The application routing check below |
| `background-check/` | Checks that Chromium's media plays on through the phone app's background and foreground ([README](background-check/README.md)) |
| `resize-check/` | A Vulkan window whose picture shows how the phone places it as the window changes size ([README](resize-check/README.md)) |
| `game-check/` | Builds a native vkQuake for checking games on the phone's GPU ([README](game-check/README.md)) |
| `emulation-check/` | Offscreen Vulkan feature checks on MoltenVK ([README](emulation-check/README.md)) |

## Offscreen feature checks

[emulation-check](emulation-check/README.md) builds a bounded offscreen Vulkan renderer
and checks real image samples on a selected stock MoltenVK archive. Control, cull-distance,
direct geometry, indirect geometry and indexed-indirect geometry are reported separately;
unsupported features are not enabled or counted as passes.

## Application routing check

[docs/gpu-live.md, "Applications"](../../docs/gpu-live.md#applications) describes how the
owner's display routes every toolkit to the phone's GPU. `check-apps.sh` checks it without
a phone, in a disposable container of a computer image with `vulkan-tools`, `mesa-utils`
and `gtk-4-examples` added:

```sh
guest/display/scripts/dev.sh cargo build --release -p caboose-display -p caboose-display-probe
guest/gpu/check-apps.sh IMAGE guest/display/target/release path/to/libvulkan_gfxstream.so [OUT]
```

It installs the driver with `install-live.py --driver`, starts a private caboose-display as
the owner's seat with the private GPU sockets, watched by caboose-display-probe, and checks
its launch environment. `socket-recorder.py` then stands in for the broker on its two
sockets: it records which process opens one and closes the connection, as happens when no
phone is attached. For Vulkan on Wayland and X11 (`vkcube`), GTK 4 (`gtk4-widget-factory`)
and Chromium it checks that the Vulkan loader loaded the driver, that the
application's own process (Chromium's GPU process) opened the broker's
socket, and that the application went on to draw on the computer: a window with a picture,
read through the display's control socket, or a clean exit. Logs, the socket record and the
windows' pictures stay in OUT (default `guest/gpu/out/apps`). `CABOOSE_CHECK_CPUS` and
`CABOOSE_CHECK_MEMORY` (default 4 and 4g) bound the container. Whether the phone renders
what arrives is for a trial with a phone. `bash guest/gpu/check-apps.sh --here [OUT]` runs
the same steps as root where everything is installed.
