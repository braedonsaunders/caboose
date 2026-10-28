# Caboose for iOS

The iPhone and iPad app, and **CabooseKit**, its native display client: Xpra, and Caboose
Display (docs/display.md) where the host serves it.

## Layout

- `CabooseKit/` — Swift package, no app UI. `Session/DisplaySession` is the window model
  the app works against; `XpraSession` and `CabooseDisplaySession` implement it.
  `Protocol/` (rencodeplus codec, Xpra packet framing, the WebSocket byte stream),
  `Session/` (Xpra capabilities and HMAC challenge, the window registry, per-window draw
  pipelines with flow-control acks, clipboard, notifications, keyboard mapping),
  `Display/` (the Caboose Display Protocol: canonical CBOR, framing, messages, the session,
  per-window frame pipelines, video streams), `Video/` (VideoToolbox H.264, HEVC and AV1 → IOSurface BGRA,
  Metal window surfaces), `Input/` (typing buffer, trackpad gestures, touch slots),
  `UI/RemoteWindowView` (presentation, video layers, and touch/Pencil/trackpad/keyboard input).
- `Caboose/` — the app: setup, wake, Home (open windows and the computer's apps), and the
  full-screen window screen.
- `Share/` — the share extension (target `CabooseShare`).
- `Caboose/Brand/` — the logo drawn natively in SwiftUI: the wordmark draws itself in on
  setup, rolls while the computer wakes and shows its hubs unlit while it is parked, and
  one of its wheels marks the computer menu. It is the same geometry and timing as
  `apps/web/src/brand/brand.ts`; change both together.
  The app icon is rendered from that module's SVG by `scripts/render-app-icon.sh` (macOS).

## Agents

The Ask bar on Home starts a Claude Code or Codex task; its menu has **Ask Before Acting**
(Claude only), which makes the agent stop before each action until you tap Allow or Deny,
on the task card or on the banner that shows over any screen. A finished task takes a reply
that continues the same conversation. A window's `…` menu has **Ask Agent About This
Window**, which sends its screenshot, title and app with your request.

## Play on iPhone or Apple TV

Video reaches the phone like every other window. When the computer's Chromium is playing a
video, its window's `…` menu also has **Play on iPhone or Apple TV**, which pauses the
computer's copy and plays it here: a video with its own http(s) source (a file or HLS) in
AVKit, with AirPlay to an Apple TV, and **Back to Computer** continues the computer's copy
at the phone's time; a stream the page builds itself opens the page in Safari's in-app
browser, and closing it continues the computer's copy where it paused. It works the same for
every site (contract: `docs/architecture.md` § Media handoff).

## Share sheet

Caboose appears in the iOS share sheet. A web page can be opened in the computer's browser;
photos, files and text can be saved in `~/Downloads` (and opened there); any of them can be
handed to an agent with a request (photos are scaled to 2048 px, at most 4 files and 10 MB).
The app and the extension share the host address and token through the Keychain access group
`<team>.com.braedonsaunders.caboose.shared`; an install that paired before this moves its
pairing there on first launch, so it does not need pairing again. On a device, check: share a
Safari page and pick Open on Computer; share a photo and pick Save and Open; share a photo
with "describe this" to an agent and see the task appear on Home.

## Computer settings

Home's menu, the parked screen and the failure screen open **Computer**: the computer's name,
the memory and cores it boots with (applied on the next restart, with a banner until then),
how long it waits before parking, Park Now, Restart (confirmed first: open apps close, the
disk is kept) and Change Computer. It reads and writes the host's management API
(`GET /v1/computer`, `PATCH /v1/computer/settings`, `POST /v1/computer/restart`, see
`docs/architecture.md`) and follows `computer.settings` events on the control socket.

## Build

```sh
brew install xcodegen
cd apps/ios
cp Caboose/Config/Local.xcconfig.example Caboose/Config/Local.xcconfig   # optional: pre-fill your host
xcodegen generate
open Caboose.xcodeproj
```

Set your own team in `project.yml` (`DEVELOPMENT_TEAM`) to run on a device. The share
extension's bundle id is the app's plus `.share`, and both sign with the keychain group in
`Caboose/Caboose.entitlements`.

## Test

```sh
cd apps/ios/CabooseKit && swift test
```

The Caboose Display tests replay the compositor's golden vectors from
`guest/display/vectors` (every message decodes, re-encodes byte for byte and parses, and
every client message the app sends matches its vector), drive `CabooseDisplaySession`
over a mocked transport (handshake, windows, acks and keyframe recovery, vsync, input,
text and preedit), and decode the vectors' H.264 and HEVC keyframes and an AV1 stream
(`Tests/CabooseKitTests/Fixtures`) in hardware; the AV1 test runs where the Mac has an
AV1 decoder (M3 and later).

Against a real computer, with the host on `CABOOSE_DISPLAY=caboose` and a window open:

```sh
CABOOSE_HOST_URL=http://host:7310 CABOOSE_HOST_TOKEN=… swift test --filter LiveCabooseDisplay
```

Or straight to a compositor, such as the dev container in `guest/display`, with
`CABOOSE_DISPLAY_URL=ws://box:14600/ CABOOSE_DISPLAY_TOKEN=…` instead. It wakes the computer
(through a host), connects, waits for every window's keyframe,
ticks vsync at 120 Hz for ten seconds (`CABOOSE_VIDEO_SECONDS`), and prints the server's
encoders and features, the windows, pictures per second, failed decodes and the round
trip.

## How it renders

Each Linux window keeps a BGRA Metal texture. PNG/JPEG/WebP draws are uploaded into it;
H.264 draws are decoded by VideoToolbox into IOSurface-backed pixel buffers and copied in
on the GPU, so video never touches the CPU. The window view presents the texture into a
`CAMetalLayer` only when a draw changed it. Every draw is acknowledged with its decode
time; the server paces itself on those acknowledgements.

## How input works

Swipe scrolls with momentum, tap clicks, double-tap double-clicks, a two-finger tap or a
long press is a right click, and long press then move drags with the primary button. A
trackpad or mouse hovers, clicks and right-clicks precisely.

With the desktop on a TV the phone is a trackpad: one finger moves the cursor, tap clicks,
two fingers scroll, a two-finger tap right-clicks, two quick taps double-click and tap then
touch and move drags. Those rules live in `CabooseKit/Input/TrackpadGestures.swift` and are
unit-tested with staggered fingers, because real fingers never land or lift together.
On a device, check that a two-finger tap opens a context menu even right after a tap,
that two fingers that move scroll without a click, and that tap-tap opens a desktop file. The iOS keyboard types through `UITextInput` (`CabooseKit/UI/RemoteTextInputView.swift`), with
the edits turned into keystrokes by `CabooseKit/Input/TypingBuffer.swift`, which is unit-tested
for autocorrect, swipe words, marked text and deletes. On a device, check in Chromium's address
bar that a misspelt word is corrected in place, that a swiped word arrives whole, that the
Japanese Romaji and Chinese Pinyin keyboards commit their candidates, and that the terminal
gets no autocorrect until `Aa` on the key bar turns it on. Hardware
keys are sent as X keys, with ⌘ mapped to Control so ⌘C/⌘V/⌘T do what Mac users expect.

## Caboose Display

When `/v1/session` answers `protocol: "caboose-display"`, the app speaks the Caboose Display
Protocol instead of Xpra; the screens are the same. What changes:

- **Pictures.** Each window is its own HEVC (or AV1 where the device decodes it in
  hardware, A17 Pro and M3 or later, or H.264) stream, decoded by VideoToolbox and drawn
  into the window's texture on the GPU with the encoder's padding cropped off and scaled
  when the window's pixels differ. Every frame is acknowledged with its decode time; a
  failed one is acknowledged with −1 and asks for a keyframe, and the frames that depend
  on it are skipped until it arrives. Lossless PNG/WebP tiles repaint static text.
- **Pacing.** Every window view on screen, previews and the desktop included, sends
  `vsync` from its own screen's display link, at 120 Hz on ProMotion
  (`CADisableMinimumFrameDurationOnPhone`) and at the TV's rate on a TV. The server
  releases a window's frames on those ticks, so a window nobody sees costs nothing.
- **Touch.** Native Wayland windows take real multi-touch: every finger is a wl_touch
  slot, and each UIKit event is one touch frame, so pinch, swipe and long-press are the
  app's own. Xwayland windows keep the pointer gestures above, since X11 apps turn a
  touch drag into a selection. The desktop on a TV or on the device's own screen keeps
  its pointer.
- **Apple Pencil** is a tablet: pressure, tilt and azimuth on every coalesced sample
  (240 Hz), and hover on iPads that have it.
- **Keyboard.** The keyboard follows the app's own text-input state instead of guessing
  from the cursor shape, and the field's purpose turns autocorrect off in terminals and
  password fields. Text goes as text-input-v3 commits and deletions; where the app has
  text-input-v3, marked text (Chinese, Japanese, Korean) is a real preedit instead of
  typed and retyped.
- **Video in windows.** A video an app plays (its own bitstream through the computer's
  VA-API driver, or a Wayland video surface) arrives as a stream of its own and is layered
  into its window: an `AVSampleBufferDisplayLayer` per stream at the stream's `rect`, cut
  to its `clip`, in `z` order over the window's picture, decoded in hardware. An app's own
  stream plays on its own timestamps through an `AVSampleBufferRenderSynchronizer` (80 ms
  behind the first picture; a seek restarts it), while live surfaces are shown as they
  decode. HDR streams (PQ, HLG) are shown with the screen's extended dynamic range. Home's
  thumbnails leave video to the window's own screen. The `video.*` messages follow the
  proposal in the compositor thread and are provisional until docs/display.md and the
  golden vectors carry them.
- **Not yet.** No sound (the protocol's Opus `audio` is a later milestone of the
  compositor; a video's sound will join its synchronizer), and window pictures are SDR:
  the hello reports `hdr: false` until the window surfaces render EDR.

