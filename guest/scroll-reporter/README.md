# Scroll reporters

Toolkit scroll reporters tell caboose-display where an application's content is scrolled in
each frame it draws. The phone then places every captured picture by its exact offset
instead of measuring pixels ([docs/display.md, "Scroll reports"](../../docs/display.md#scroll-reports)).
Each reporter connects to the display instance's `scroll.sock` (`$CABOOSE_SCROLL_SOCKET`);
the socket protocol is described in
[guest/display/compositor/src/scroll.rs](../display/compositor/src/scroll.rs).

## Chromium

`chromium/` is a Manifest V3 extension with the native messaging host
`com.caboose.scroll`:

- `content.js` runs in each top-level page. In every frame, once layout is done (a
  ResizeObserver on its own probe element), it reads the root scroller and the largest
  inner one, their ranges, and the fixed and stuck sticky elements over them. While a
  client places pictures by reports, it does this every frame. It also draws the frame
  tag in the window's bottom overscan in the same frame, so each picture names its
  report. It applies `scroll.target` deltas in the next frame, before measuring, and
  reports their sequence as `applied`. A layout shift is noticed from a few sample
  elements' document positions and starts a new `epoch`.
- It reads the visual viewport too. Under a pinch zoom it reports offsets and ranges in
  zoomed pixels, maps every rectangle through the zoom, and draws the tag where it lands on
  its window pixels. `scroll.zoom` is applied in frame order after the scroll before it. The
  service worker (or the Electron reporter) performs a trackpad pinch through the debugger,
  anchored inside the window. The page then scrolls, frame after frame, until the content at
  the zoom's focus is where it belongs, and applies the seq in that frame. While a zoom is
  settling it draws no tag. Chromium is started with `--silent-debugger-extension-api` (an
  `/etc/chromium.d` file from `install.sh`), so attaching the debugger shows no banner.
- `core.js` is its pure logic: the tag's blocks, the tag's place, the sticky test and
  report comparison.
- `service-worker.js` joins the visible tab to the native host.
- `caboose-scroll-host.mjs` (Node, no dependencies) passes whole messages between
  Chromium's stdio and `scroll.sock`. Both use the same framing.

Limitations: one browser profile reports one window at a time (the one whose tab reported
last). Cross-origin iframes are not reported. Pages served from `file://` are not reported
unless the user allows the extension on file URLs. While the phone scrolls a page by any
other means than `scroll.target` (pointer scroll animated on Chromium's compositor
thread), a picture can show an offset its tag's report does not have yet. The phone
therefore places pictures by reports only while it drives the page with `scroll.target`.

## Electron

`electron/main.js` is the Chromium reporter for Electron applications, which do not load
Chromium extensions. caboose-display puts `NODE_OPTIONS=--require=/opt/caboose/scroll-reporter/electron/main.js`
in its launch environment (the Flatpak override passes it too). Electron loads it into an
application's main process; in plain Node and other Electron processes it returns at once.
Once the application's main script has run, it attaches Electron's debugger to each window's
web contents. It runs `chromium/core.js` and `content.js` in an isolated world of every
document, and joins each window to `scroll.sock` with a connection of its own. The page's
reports reach it through a binding; bind, unbind and target messages go back in by
evaluation. Every step is guarded, so a reporter fault never takes the application down.

Limitations: applications that turn off Electron's `EnableNodeOptionsEnvironmentVariable`
fuse (Obsidian, among others) ignore `NODE_OPTIONS` and are not reported. A window whose
DevTools hold the debugger is not reported.

## GTK 3 and GTK 4

`gtk/caboose-scroll-gtk.c` builds into the preload libraries `libcaboose-scroll-gtk4.so` and
`libcaboose-scroll-gtk3.so`. Both GTKs are linked `-Bsymbolic` with immediate binding, so no
call inside GTK can be interposed. The reporter uses only public API, resolved with `dlsym`,
so it links to neither GLib nor GTK and does nothing in other processes:

- Every quarter second it hooks new toplevels. After GTK's own layout in each frame (the
  frame clock's layout phase), the adjustments of every GtkScrolledWindow hold what the frame
  draws. It reports the largest scrolled window first and every other one after it.
- The tag is drawn in that frame. In GTK 4 it is a GtkDrawingArea the reporter parents to
  the window and allocates itself, outside the application's layout. In GTK 3 the reporter
  draws it after the window draws. It goes in the bottom overscan, so the tag is part of the
  frame's render on every GSK renderer and on GPU presents.
- `scroll.target` moves the adjustment, and the next layout reports its seq as `applied`.
  A change of the primary adjustment's upper bound starts a new `epoch`.
- A GTK 3 client-side decorated window's coordinates start at its titlebar and content, not
  its shadow.

Limitations: applications that load GTK at run time (Python through GObject introspection)
are not reported, because the reporter looks for GTK as the process starts.

## Qt Quick

`qt/` builds `libcaboose-scroll-qt6.so`, a preload library that links to nothing. In a
process with Qt Quick it loads `libcaboose-scroll-qt6-quick.so` from its own directory. That
registers a Qt pre-routine, which runs once the application object exists, and then hooks
every QQuickWindow. In `afterAnimating` (the GUI thread, before the scene graph
synchronizes the frame) it reads every Flickable's `contentX`, `contentY`, origin, content
size and scene rectangle through properties alone, without Qt's private headers. The tag is
a QQuickItem of its own, drawn with scene graph rectangles over the window's content and
updated in that same step. `scroll.target` moves `contentX`/`contentY`.

`caboose-display` preloads every `libcaboose-scroll-*.so` built for its architecture
(`/opt/caboose/scroll-reporter/lib/MULTIARCH`) into the applications it launches, through
its launch environment, as `/opt/caboose/scroll-reporter/$LIB/NAME`.

## 32-bit applications

The dynamic loader expands `$LIB` to each process's own library directory, `lib/x86_64-linux-gnu`
or `lib/i386-linux-gnu` on Debian, in the Freedesktop runtimes and in Steam's runtime, so a
32-bit process loads the i386 builds. On x86-64 the image builds every reporter for i386 too:
`build.sh` takes `CC`, `CXX` and `PKG_CONFIG`, and writes into `out/MULTIARCH` of the
compiler's triplet:

```sh
CC=i686-linux-gnu-gcc CXX=i686-linux-gnu-g++ \
  PKG_CONFIG="env PKG_CONFIG_LIBDIR=/usr/lib/i386-linux-gnu/pkgconfig:/usr/share/pkgconfig pkg-config" \
  gtk/build.sh
```

with Debian's i686 cross compilers and the toolkits' `:i386` development packages.
`install.sh` refuses to install an architecture that lacks a preload the computer's own
architecture has, since its processes would report the missing library.
`check-preloads.sh` builds the image's preloads stage and starts a 64-bit and a 32-bit
process with every preload: each must load its own architecture's build of each, with no
complaint from the dynamic loader.

## Flatpak

Flatpak applications see neither `/opt` nor the host's `LD_PRELOAD`. `install.sh` adds a
system-wide override giving every Flatpak application the libraries read-only (preloaded by
`$LIB`, as above), the display
instances' sockets (`xdg-run/caboose-display`) and the preload. In a sandbox the reporters
find their scroll socket from `WAYLAND_DISPLAY` when `CABOOSE_SCROLL_SOCKET` is not passed
in, at the same path as on the host. Binding by process lineage works across the sandbox's
process namespace, since the compositor sees host process ids. The libraries need glibc
2.34 and link nothing else, so they run in the Freedesktop, GNOME and KDE runtimes. The Qt
part links the host's Qt 6.8 and loads into KDE runtimes from 6.8 on (6.10 and 6.11 are the
ones Flathub publishes). Qt 5 Quick applications are not reported.

`CABOOSE_SCROLL_DEBUG=1` makes the Qt reporter say on stderr which windows it hooked,
whether it connected and which windows have no Flickable.

### Install

`install.sh` (as root, in the image build, after Chromium and Node) installs the GTK and Qt
preload libraries when built (`guest/container/Dockerfile` builds them in its preloads stage, for i386 too on x86-64)
and the extension to `/opt/caboose/scroll-reporter`, registers the native host for Debian's
Chromium and links the extension into `/usr/share/chromium/extensions`, which Debian's
launcher loads. `guest/container/Dockerfile` runs it.

### Test

- `node --test guest/scroll-reporter/chromium/core.test.mjs`: the pure logic, including the
  tag against `guest/display/vectors/scroll-tag/scroll-tag.json`.
- `check.py gtk4-scroll-reports`, `gtk3-scroll-reports` and `qt6-scroll-reports`: the same
  check on the toolkits' ruler applications (`gtk/ruler-app.c`, `qt/ruler-app.cpp`, built by
  `build.sh --check`; `CABOOSE_SCROLL_GTK`/`CABOOSE_SCROLL_QT` name the build directories).
- `check.py electron-scroll-reports`: a stock Electron (`CABOOSE_SCROLL_ELECTRON` names its
  binary) with the reporter through `NODE_OPTIONS`, showing the ruler page
  (`electron/ruler-app`).
- `check.py chromium-zoom-scroll-reports`, `chromium-zoom-outside-scroll-reports` and
  `electron-zoom-scroll-reports`: the same check, with a `scroll.zoom` partway through (focus
  in or below the window). They also require the first frame that applies it to be at its
  scale, with the focus content where it was.
- `check.py chromium-scroll-reports` (in [guest/display/scripts](../display/scripts)):
  real Chromium on caboose-display with the extension and native host. The probe asks for
  overscan and drives the page with `scroll.target`. For every decoded picture it reads
  the tag and looks up the report it names. It then reads the page's true offset from a
  ruler the page draws (`pages/scroll-ruler.html`) and fails if any picture's report
  disagrees by more than 1.5 px. As a control, it counts how many pictures the newest
  report on arrival would have placed wrongly. Run it as a user other than root, in a
  computer image with the built binaries:

  ```sh
  runuser -u caboose -- env HOME=/tmp/home CABOOSE_DISPLAY_BIN=<target/release> \
    python3 -c 'import check; print(check.check_chromium_scroll_reports())'
  ```
