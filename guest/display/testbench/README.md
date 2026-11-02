# Caboose testbench

An ordinary Wayland client — and, with `--x11`, an ordinary X11 client — that
tests the compositor from outside, like any application. It is the outside-in
counterpart of the compositor's own instrumentation: if the testbench sees a
frame step, the path an application uses works.

What it shows and measures:

- a marker that steps one position per frame (with the frame number encoded
  in six blocks), so a dropped or repeated frame is visible at a glance;
- `wp_presentation` feedback: when each frame was presented, the refresh
  period, and how many refreshes a gap skipped;
- every input event it receives, logged with a monotonic timestamp;
- the globals the compositor advertises, with their versions;
- a protocol checklist (core globals, shm formats, xdg configure, frame
  callbacks, presentation feedback, output mode, seat input), each item
  pass, fail or info.

## Run it

```sh
cargo build --release -p caboose-display-testbench   # in guest/display
WAYLAND_DISPLAY=wayland-caboose-0 ./target/release/caboose-display-testbench
WAYLAND_DISPLAY=wayland-caboose-0 ./target/release/caboose-display-testbench --auto 5
DISPLAY=:110 ./target/release/caboose-display-testbench --x11 --auto 5
```

`--auto [seconds]` (default 5) runs headless, prints one JSON report to
stdout, and exits nonzero when a checklist item failed. Interactive mode
runs until the window is closed.

## Tests

```sh
cargo test -p caboose-display-testbench
```

The marker, checklist and report logic is unit-tested without a compositor;
[framelab's headless check](../../framelab/check.sh) runs the real client
against a private seat in both modes.
