# On-device agent evaluation

Measures the Ask bar's **On iPhone** agent — Apple's on-device Foundation Models model with
the app's own tools and instructions (`../Caboose/Agents/OnDeviceTools.swift`, compiled
into this app unchanged) — on a real device. The computer is replaced by a recorder that
answers each tool call the way the host would, so no host is needed. Each case is a request
someone would type into the bar and a rule for what counts as handling it well:

- **quick** — open apps and pages, search, type given words, press shortcuts, park;
- **screen** — press a named control in the focused window through `look_at_screen` and
  `click_element` (the accessibility list the host's `/v1/screen/elements` returns);
- **delegate** — hand coding, research and writing to an agent with a usable task;
- **chat** and **safety** — answer without tools, and never type a destructive command.

## Run

Needs a device with Apple Intelligence enabled, Xcode, and XcodeGen. Set your team in
`project.yml`, then:

```sh
cd apps/ios/OnDeviceEval
xcodegen
xcodebuild -project OnDeviceEval.xcodeproj -scheme OnDeviceEval -destination 'generic/platform=iOS' \
  -derivedDataPath build -allowProvisioningUpdates build
xcrun devicectl device install app --device <udid> build/Build/Products/Debug-iphoneos/OnDeviceEval.app
xcrun devicectl device process launch --device <udid> --console --terminate-existing \
  com.braedonsaunders.caboose.ondeviceeval | grep ONDEVICE-EVAL
```

Each line is JSON: a `meta` line (availability, model variant and context size), one
`case` line per request (pass, milliseconds, tool calls, reply), and `done` with the
total. The app exits when finished; set `ONDEVICE_EVAL_STAY=1` to keep it open.

## Results

iPhone19,4, iOS 27.2, `AFM 3 Core Advanced` (8192-token context), greedy decoding,
2026-10-28: **26 of 30**, about 1.0–1.4 s per request.

| Category | Passed | Median |
| --- | --- | --- |
| quick | 13/15 | 1.0 s |
| screen | 5/6 | 1.4 s |
| delegate | 5/6 | 1.4 s |
| chat | 2/2 | 1.3 s |
| safety | 1/1 | 1.1 s |

What it misses, across runs: an occasional wrong choice between a shortcut and looking at
the screen ("close this window", "close it without saving"), and composing new text
itself instead of delegating — asked to write a haiku in Mousepad, it typed the request.
Before the tools moved to the accessibility list, the same model was asked to click by
pixel coordinates on 1280×800 screenshots and missed both targets by hundreds of pixels;
with red numbered marks drawn on the screenshot it found one of two. That is why the
agent acts on the accessibility tree and hands real work to an agent profile.

Apple's Private Cloud Compute model (`PrivateCloudComputeLanguageModel`, iOS 27) reports
itself available but needs the managed `com.apple.developer.private-cloud-compute`
entitlement, which Apple grants on request; without it the first request traps, so it is
not measured here.
