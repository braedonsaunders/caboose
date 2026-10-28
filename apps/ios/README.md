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
- `OnDeviceEval/` — a small app that measures the On iPhone agent on a device.
- `Caboose/Brand/` — the logo drawn natively in SwiftUI: the wordmark draws itself in on
  setup, rolls while the computer wakes and shows its hubs unlit while it is parked, and
  one of its wheels marks the computer menu. It is the same geometry and timing as
  `apps/web/src/brand/brand.ts`; change both together.
  The app icon is rendered from that module's SVG by `scripts/render-app-icon.sh` (macOS).

## Agents

The Ask bar on Home starts a task with the computer's default agent or any agent installed
from the Agent Client Protocol registry; its menu has **Ask Before Acting**, which makes the
agent stop before each action until you tap Allow (or the agent's always-allow option) or
Deny, on the task card or on the banner that shows over any screen. A finished task takes a
reply that continues the same conversation; one whose agent was signed out offers Sign In.
Settings › Agents (from the bar's menu or Computer settings) installs and updates agents,
signs in to them on the computer's screen, gives one an API key or other environment, and
sets the default.

Where Apple Intelligence is available the bar also offers **On iPhone**: Apple's on-device
model, in `Caboose/Agents/OnDevice*.swift`. It opens apps and pages, types, presses
shortcuts, presses buttons in the focused window by name (through the host's accessibility
routes), parks the computer, and hands anything bigger to a computer agent. Its requests
show on Home with each step it took. `OnDeviceEval/` measures it on a device (its own
README). A window's `…` menu has **Ask Agent About This
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
The share extension stages files on disk and streams them to the computer; the size limit
for agent attachments still applies. The app and the extensions share the host address and token through the Keychain access group
`<team>.com.braedonsaunders.caboose.shared`; an install that paired before this moves its
pairing there on first launch, so it does not need pairing again. On a device, check: share a
Safari page and pick Open on Computer; share a photo and pick Save and Open; share a photo
with "describe this" to an agent and see the task appear on Home.

## Files app

The paired computer appears as a Files location named after the computer. Files can enumerate
its home, download on demand, create folders, upload edits, rename, move and delete items.
The replicated provider uses version checks for coordinated writes and polls the guest's sync
anchor when its enumerator wakes; the app signals it on live `fs.changed` events. The system
can generate previews for downloaded items; there is no separate server thumbnail service.
A parked computer wakes for file access. An unreachable host is reported as offline.

On a signed device paired to a guest with `guest/files` installed, open the location in Files,
create a folder, save a document from another app, open and edit it in place, and verify the
edit on Linux. Rename and move it from each side, verify changes appear after reconnecting,
then delete it in Files and check the guest Trash. Park the computer and open a file to verify
wake; disconnect the network and verify Files reports the host unavailable without discarding
an offline edit. Verify a conflicting Linux edit is not overwritten. A simulator build alone
does not verify the File Provider daemon or device entitlements.

## Drop into Linux

Drop text on an owner window to focus the drop point and type it. Drop a file or image to
save it in `~/Downloads` and open it with Linux's default handler (up to 50 MiB); this does
not deliver a native drag event to the target app. Dragging out of Linux is not implemented.

On a real iPad, connect to the computer, open a text editor, then drop selected text from
another app into its edit area. Check that the text appears at the drop point. Drop an image
from Photos and a document from Files; check Downloads and the default viewer. Repeat with
Xpra and Caboose Display, and with the app in its full-screen and desktop layouts. Try a
file over 50 MiB and verify the error is shown. The iPhone can receive drops where iOS makes
a drag source available. Device checks require a real computer and iOS device.

## Open, share and print from Linux

`caboose-open` opens a supported link on the phone after confirmation. In Thunar use
**Share to iPhone**, or run `caboose-share FILE`; selecting **iPhone** in a Linux print
dialog sends a PDF to the phone's print dialog. Share and print files are limited to
10 MiB. Requests wait in the guest while the phone is disconnected, expire after 24 hours,
and are delivered at most once. Every action asks first; no background URL opens. The
`PhoneFileDownloading` protocol currently uses the bounded guest-command download; the
streamed `/v1/fs` API is available for a later handoff-client upgrade.

For a real-device check, connect to the computer, open a terminal, run
`caboose-open 'mailto:person@example.com'`, and confirm only after verifying the URL.
Share a photo from Thunar and verify the native share sheet can save it or AirDrop it;
print a document to iPhone and verify the AirPrint preview and printer selection. Repeat
with the phone backgrounded and with both Xpra and Caboose Display; no action should occur
without a tap. Open the app again to receive queued requests. See `guest/phone/README.md`
for the scripted guest check.

## Computer settings

Home's menu, the parked screen and the failure screen open **Computer**: the computer's name,
the memory and cores it boots with (applied on the next restart, with a banner until then),
how long it waits before parking, Park Now, Restart (confirmed first: open apps close, the
disk is kept) and Change Computer. It reads and writes the host's management API
(`GET /v1/computer`, `PATCH /v1/computer/settings`, `POST /v1/computer/restart`, see
`docs/architecture.md`) and follows `computer.settings` events on the control socket.

## Shelf and Library

Home's Shelf offers optional applications from the computer's pinned catalog. Tap Get
and follow its live install indicator; the installed application appears in the app grid.
Library groups applications into packs and offers updates, rollback when an older release
is cached, and removal. Debian applications come from Debian 13; Craft release versions
change only when this repository's catalog pin is changed, then the owner chooses Update.

On a device connected to a deployed computer, install PhotoCraft from the Shelf, verify
progress and that Open launches a window, then check Library's pack and Remove actions.
An update and rollback check needs a computer with an older pinned Craft release cached.

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
  to its `clip`, in `z` order over the window's picture. Frames come in decode order and
  are decoded in hardware as they arrive, in the decoder's own format. A live surface is
  shown as each picture decodes; an app's own stream keeps its pictures by `seq` and shows
  each when `video.present` says the app is showing it. A region of any window that
  updates at video rates (a canvas, a game, a player the server cannot see into) arrives
  the same way as a `motion` stream, and the window's own picture leaves that region out
  while it plays. When it ends, the server repaints the region into the window and then
  destroys the stream; the stream's layer stays until the window view has shown that
  repaint, so the stale pixels underneath never flash. HDR streams (PQ, HLG) are shown
  with the screen's extended dynamic range. Home's thumbnails leave video to the window's
  own screen.
- **Sound.** The hello asks for Opus (`audio_decoders`), and the computer's sound arrives
  as 20 ms Opus packets stamped on the server's clock. Each is decoded by the system's Opus
  decoder (AudioToolbox) and played by an `AVSampleBufferAudioRenderer`, so iOS routes it
  like any app's sound: speaker, AirPods, AirPlay, mixed with other apps under the app's
  `.playback` session. The renderer and every video layer share one
  `AVSampleBufferRenderSynchronizer` per session, whose timeline is the server's clock, so
  a video and its sound play in step. The clock starts 40 ms behind the first packet,
  which absorbs a LAN's jitter while keeping a click's sound close to its picture. A late
  packet adds 20 ms (up to 200 ms), a backlog is dropped, and silence the computer does not
  send is a gap the clock runs through. With no sound playing, pictures show as they
  arrive; window pictures always do. The display closes when the app goes to the
  background, and the sound with it.
- **One device at a time.** The computer's display shows on one device. When another (a
  TV, an iPad) takes it, this one gets `bye { reason: "replaced" }`, says it is showing on
  another device, and does not reconnect on its own (not even on returning to the app),
  so two devices never take it back and forth; Show Here takes it back. The session's ping
  every 5 s keeps the server from closing it as idle (30 s).
- **Not yet.** Window pictures are SDR:
  the hello reports `hdr: false` until the window surfaces render EDR.


## Notifications

When the host has APNs configured, Computer settings lets this device choose approval,
finished-task, and desktop alerts and request iOS notification permission. Approval
actions answer the host's existing approval API; task alerts open the task. The app
unregisters its token when changing computers. A development-signed app uses APNs
sandbox and a release-signed app uses production; signing must include the push
capability. Check on a real paired device by enabling each kind, backgrounding the app,
triggering an approval and a task completion, and using Allow and Deny from notifications.
A Linux notification has no portable window identifier and opens Caboose.

## Live Activities

The app starts a Live Activity for running agent tasks when the host has APNs, and the
host updates and ends it while the app is closed. `CabooseWidgets` is the shared WidgetKit
extension for these Lock Screen and Dynamic Island views; later widgets and controls belong
in this target. Its shared `JobAttributes` also describes generic jobs, with the host API in
`docs/architecture.md` § Notifications. Push-to-start uses ActivityKit's token stream.
On a signed device with APNs configured, start a task, background the app, verify the Lock
Screen/Dynamic Island updates and ends on completion, then start a task from another client
and verify push-to-start. Real delivery depends on iOS and APNs and cannot be proved by a
simulator build.

## Shortcuts and Spotlight

Shortcuts can wake or park the computer, open a Linux app or web URL, start an agent
task and open, get or save files. File actions require the file service in the guest;
uploads never overwrite a file. Agent tasks request approval and return a task link.
Apps and files used through file actions can appear in Spotlight. On a paired device,
run each action in Shortcuts, verify Siri phrases, open an indexed app and file, and
check that sign-out removes search entries. These integrations require a real device and
a computer with the `/v1/fs` service.

The Computer widget displays the latest fetched state and running agent count; the
Control Center Computer Power toggle wakes or parks it. On a signed paired device, add
the widget and control, compare the displayed state with Computer settings, and toggle
the computer in both directions. WidgetKit schedules refreshes and may delay updates.
File suggestions currently show files in the home root; Spotlight file entries are
cleared on a file-change notification.

Craft actions, widget favourite-app launch, and favourite-app and Ask Agent controls
are not implemented. File suggestions currently cover the home root only.
