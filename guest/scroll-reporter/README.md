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

### Install

`install.sh` (as root, in the image build, after Chromium and Node) installs the
extension to `/opt/caboose/scroll-reporter`, registers the native host for Debian's
Chromium and links the extension into `/usr/share/chromium/extensions`, which Debian's
launcher loads. `guest/container/Dockerfile` runs it.

### Test

- `node --test guest/scroll-reporter/chromium/core.test.mjs`: the pure logic, including the
  tag against `guest/display/vectors/scroll-tag/scroll-tag.json`.
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
