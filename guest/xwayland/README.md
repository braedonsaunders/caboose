# Xwayland with DRI3 on the render node

The computer's Xwayland is Debian's, built with the patch here. A computer's only DRM
device is the `vgem` render node ([docs/gpu-buffers.md](../../docs/gpu-buffers.md)),
which has no GL driver, so Xwayland runs without glamor and, unpatched, without DRI3.
X11 clients then have no way to open the render node: Chromium on X11 takes its GBM
device from DRI3, and without one it cannot import the NV12 buffers the VA-API driver
decodes into, so video in Chromium, Electron and Steam's web views would be decoded and
uploaded on the computer instead of on the phone ([docs/gpu-media.md](../../docs/gpu-media.md)).

| File | What |
| --- | --- |
| `dri3-render-node.patch` | Without glamor, DRI3 opens the render node named by `CABOOSE_XWAYLAND_RENDER_NODE` |
| `build.sh` | Builds Debian's `xwayland` package with the patch, versioned `+caboose1` |

The patched server answers DRI3 `Open` with a descriptor of the node and advertises
nothing else: `PixmapFromBuffers` fails, so buffers are never imported as pixmaps and
presentation is unchanged. caboose-display sets the variable for its Xwayland on the seat
that renders on the phone's GPU, when the computer has a vgem render node. Mesa's GLX and
EGL clients then try DRI3 first, find no GL driver for `vgem` and fall back to their
software path as before (they print `failed to load driver: vgem`).

## Building

```sh
guest/xwayland/build.sh OUTPUT_DIRECTORY
```

in a Debian 13 environment with `deb-src` entries, `apt-get build-dep xwayland` and
`dpkg-dev`; the container image builds it in its `xwayland` stage. The patch is against
the release's Xwayland (24.1); a release whose source it does not apply to fails the build.

## Checking

On a computer, or in a container of the image with `/dev/dri` passed through, with
caboose-display running as the GPU seat:

```sh
xdpyinfo | grep DRI3
```

lists the extension, and Chromium started with the seat's flags logs no
`SharedImageBackingFactory` errors while it plays a video through the VA-API driver.
