# Touch-targeting benchmark

How often a finger tapping a desktop control on the phone presses that control, without and
with aiming ([docs/display.md, "Touch targets"](../../docs/display.md#touch-targets)). The
provider is `guest/desktop-mcp/caboose-targets.py`; the aiming is
`apps/ios/CabooseKit/Sources/CabooseKit/Input/TouchTargeting.swift`.

| File | Is |
| --- | --- |
| `bench/gtk3-targets.py` | A GTK 3 window dense with small controls: a menu bar, a toolbar, flat icon buttons, check boxes, radios, link buttons, spin buttons, a combo, an entry, a scale, tab close buttons, a tree view, and a More button that shows and hides a row of buttons. It prints its own layout (the truth) and every press it gets |
| `bench/targets.html` | The same for Chromium: a toolbar, 16 px icons, check boxes, radios, inline links in prose, form fields, table row actions, pagination and tab close buttons; it posts its layout and presses |
| `bench/bench-guest.py` | The guest side: runs each app on a seat, records the truth and the provider's reading (both window-local logical pixels) with timings, times how long after a click the client has the window's new targets, and replays taps through the seat's pointer, recording which control each reached |
| `check.sh` | Runs `bench-guest.py` in a disposable container of a computer image, with a probe as the client asking for targets |

Fixtures go to `apps/ios/CabooseKit/Tests/CabooseKitTests/Fixtures/touch-targets/` (the
`app`, `window`, `truth`, `provided` and `timings` keys of each app's output, and its
picture, `<app>.png`).
`TouchTargetingBenchmarkTests` simulates fingers on them: each tap aims near a control's
middle and lands with a Gaussian error of 1.0, 1.5 or 2.0 mm, at 0.5, 0.75 and 1 phone
points per window pixel, and is scored for the bare finger, the nearest control within two
spreads, `TouchAim`, `TouchAim` with a magnified second look at ambiguous taps, and
`TouchAim` over the shapes `PictureTargets` finds in the window's picture around the touch,
for windows without an accessibility tree. `bench-guest.py --survey` reads the image's own
applications (a terminal, an editor, a file manager, VS Code, Chromium, LibreOffice) and
reports how many targets each yields and how long reading took.

```sh
# On a machine with Docker and a computer image; BIN is a release build of guest/display.
guest/touch-targets/check.sh caboose-computer:IMAGE OUT BIN -- --apps gtk3-x11,gtk3-wayland,chromium-wayland
# On the Mac: the table (and, with TOUCH_BENCH_CLICKS, taps to replay with --clicks).
cd apps/ios/CabooseKit && swift test --filter TouchTargetingBenchmark
```

`bench-guest.py --clicks FILE` replays `{"<app>": [{"at": [x, y], "want": NAME, "tag"}]}`
through the seat's pointer and records the control each press reached. The apps' own
layouts are the truth; the provider's reading is what the phone gets.
