# Caboose for iOS

The iPhone and iPad app, and **CabooseKit**, the Swift package that connects it to the
computer's display over the Caboose Display Protocol ([docs/display.md](../../docs/display.md)).

## Layout

| Path | What |
| --- | --- |
| `CabooseKit/` | Swift package, no app UI. `Session/` holds the window model the app works against (`DisplaySession`, `RemoteWindow`, the screen description, keyboard mapping). `Display/` is the protocol: canonical CBOR, framing, messages, `CabooseDisplaySession`, per-window frame pipelines, video streams and sound. `Video/` decodes H.264, HEVC and AV1 with VideoToolbox into IOSurface-backed BGRA and keeps each window's Metal surface. `Input/` has the typing buffer, trackpad gestures and touch slots. `UI/RemoteWindowView` presents a window and takes touch, Pencil, trackpad and keyboard input. |
| `Caboose/` | The app: pairing, wake, Home (open windows and the computer's apps), window screens, the desktop on a TV or iPad, agents, settings, intents. |
| `Caboose/Brand/` | The logo drawn natively in SwiftUI. It shares geometry and timing with `apps/web/src/brand/brand.ts`; change both together. `scripts/render-app-icon.sh` renders the app icon from the same SVG (macOS). |
| `Share/` | The share extension (target `CabooseShare`). |
| `Files/` | The File Provider extension that shows the computer in the Files app. |
| `Widgets/`, `Shared/` | The WidgetKit extension: widgets, controls and Live Activities. |
| `OnDeviceEval/` | A small app that measures the On iPhone agent on a device ([its README](OnDeviceEval/README.md)). |

## Build

```sh
brew install xcodegen
cd apps/ios
cp Caboose/Config/Local.xcconfig.example Caboose/Config/Local.xcconfig   # optional: pre-fill your host
xcodegen generate
open Caboose.xcodeproj
```

Set your own team in `project.yml` (`DEVELOPMENT_TEAM`) to run on a device. The extensions'
bundle ids are the app's plus a suffix (`.share`, `.files`, `.widgets`). All of them sign
with the keychain group `<team>.com.braedonsaunders.caboose.shared`, through which they
share the host address and token; the app, Files and Share extensions also share the
application group `group.com.braedonsaunders.caboose`.

## Test

```sh
cd apps/ios/CabooseKit && swift test
```

The unit tests replay the compositor's golden vectors from `guest/display/vectors` (every
message decodes, re-encodes byte for byte and parses, and every client message the app
sends matches its vector), drive `CabooseDisplaySession` over a mocked transport
(handshake, windows, acks and keyframe recovery, vsync, input, text and preedit, sound),
and decode the vectors' H.264 and HEVC keyframes and an AV1 stream
(`Tests/CabooseKitTests/Fixtures`) in hardware. The AV1 test runs where the Mac has an AV1
decoder (M3 and later).

Against a real computer with a window open:

```sh
CABOOSE_HOST_URL=http://host:7310 CABOOSE_HOST_TOKEN=… swift test --filter LiveCabooseDisplay
```

Or straight to a compositor, such as the dev container in `guest/display`, with
`CABOOSE_DISPLAY_URL=ws://box:14600/ CABOOSE_DISPLAY_TOKEN=…` instead. The test wakes the
computer (through a host), connects, waits for every window's keyframe, ticks vsync at
120 Hz for ten seconds (`CABOOSE_VIDEO_SECONDS`), and prints the server's encoders and
features, the windows, pictures per second, failed decodes and the round trip.
`CABOOSE_SOUND_CHECK=1 swift test --filter LiveSound` measures sound against picture on
the compositor's sound test page.

## How it renders

Each Linux window is its own stream: HEVC, AV1 where the device decodes it in hardware
(A17 Pro and M3 or later), or H.264. VideoToolbox decodes into IOSurface-backed pixel
buffers that are copied into the window's BGRA Metal texture on the GPU, with the
encoder's padding cropped off and scaled when the window's pixels differ, so video never
touches the CPU. Lossless PNG and WebP tiles repaint static text. The window view presents
its texture into a `CAMetalLayer` only when a picture changed it.

- **Acknowledgements.** Every frame is acknowledged with its decode time. A failed one is
  acknowledged with −1 and asks for a keyframe, and the frames that depend on it are skipped
  until it arrives.
- **Pacing.** Every window view on screen, previews and the desktop included, sends `vsync`
  from its own screen's display link, at 120 Hz on ProMotion
  (`CADisableMinimumFrameDurationOnPhone`) and at the TV's rate on a TV. The server releases
  a window's frames on those ticks, so a window nobody sees costs nothing.
- **Video in windows.** A video an app plays (its own bitstream through the computer's
  VA-API driver, or a Wayland video surface) arrives as a stream of its own and is layered
  into its window: an `AVSampleBufferDisplayLayer` per stream at the stream's `rect`, cut to
  its `clip`, in `z` order over the window's picture. An app's own stream keeps its pictures
  by `seq` and shows each when `video.present` says the app is showing it. A region that
  updates at video rates (a canvas, a game, a player the server cannot see into) arrives the
  same way as a `motion` stream. When a stream ends, the server repaints its region into the
  window and then destroys the stream; the layer stays until the window view has shown that
  repaint, so stale pixels never flash. HDR video streams (PQ, HLG) use the screen's extended
  dynamic range; window pictures are SDR.
- **Sound.** The computer's sound arrives as 20 ms Opus packets stamped on the server's
  clock, decoded by AudioToolbox and played by an `AVSampleBufferAudioRenderer`, so iOS
  routes it like any app's sound. The renderer and every video layer share one
  `AVSampleBufferRenderSynchronizer` per session whose timeline is the server's clock, so a
  video and its sound play in step. Playback starts 40 ms behind the first packet; a late
  packet adds 20 ms (up to 200 ms) and a backlog is dropped. The display closes when the app
  goes to the background, and the sound with it.
- **One device at a time.** The computer's display shows on one device. When another takes
  it, this one gets `bye { reason: "replaced" }`, says it is showing on another device, and
  does not reconnect on its own; Show Here takes it back. A ping every 5 s keeps the server
  from closing the session as idle.

## How input works

Native Wayland windows take real multi-touch: every finger is a touch slot and each UIKit
event is one touch frame, so pinch, swipe and long-press are the app's own. Apple Pencil is a
tablet with pressure, tilt and azimuth on every coalesced sample, and hover on iPads that
have it. X11 windows (through Xwayland) take pointer gestures, since X11 apps turn a touch
drag into a selection: swipe scrolls with momentum, tap clicks, double-tap double-clicks, a
two-finger tap or a long press right-clicks, and long press then move drags. A trackpad or
mouse hovers, clicks and right-clicks precisely.

With the desktop on a TV the phone is a trackpad: one finger moves the cursor, tap clicks,
two fingers scroll, a two-finger tap right-clicks, two quick taps double-click and tap then
touch and move drags. Those rules live in `CabooseKit/Input/TrackpadGestures.swift` and are
unit-tested with staggered fingers, because real fingers never land or lift together.

The iOS keyboard types through `UITextInput` (`CabooseKit/UI/RemoteTextInputView.swift`),
and `CabooseKit/Input/TypingBuffer.swift` turns its edits into text-input commits and
deletions, unit-tested for autocorrect, swipe words, marked text and deletes. The keyboard
follows the app's own text-input state, and the field's purpose turns autocorrect off in
terminals and password fields. Where the app supports text input, marked text (Chinese,
Japanese, Korean) is a real preedit. Hardware keys are sent as keys, with ⌘ mapped to
Control so ⌘C, ⌘V and ⌘T do what Mac users expect.

## Agents

The Ask bar on Home starts a task with the computer's default agent or any agent installed
from the Agent Client Protocol registry. **Ask Before Acting** makes the agent stop before
each action until you tap Allow (or the agent's always-allow option) or Deny, on the task
card or on the banner that shows over any screen. A finished task takes a reply that
continues the same conversation. Settings › Agents installs and updates agents, signs in to
them on the computer's screen, gives one an API key or other environment, and sets the
default. **Use Craft App Tools** controls whether new tasks offer installed catalog MCP
servers to the agent.

Agents run their GUI apps on the agent seat, a second display of the computer. The app
connects to it as it does to the owner's display (`/v1/display?seat=agent`, without sound),
and its windows appear in the Agent space, where you can watch them, take over and hand back.

Where Apple Intelligence is available the bar also offers **On iPhone**: Apple's on-device
model (`Caboose/Agents/OnDevice*.swift`). It opens apps and pages, types, presses shortcuts,
presses buttons in the focused window by name (through the host's accessibility routes),
parks the computer, and hands anything bigger to a computer agent. A window's `…` menu has
**Ask Agent About This Window**, which sends its screenshot, title and app with your request.

## iOS integration

- **Share sheet.** A web page opens in the computer's browser; photos, files and text are
  saved in `~/Downloads` (and opened there) or handed to an agent with a request (photos
  scaled to 2048 px, at most 4 files and 10 MB).
- **Files.** The paired computer is a Files location named after the computer: browse its
  home, download on demand, create folders, edit in place, rename, move and delete. A parked
  computer wakes for file access.
- **Open in place.** Files and Open In send a supported document to an installed catalog app
  (or install a compatible one). External documents are uploaded to `Caboose Documents` and
  kept in sync with the original; if both copies changed, you choose which to keep. After
  changing catalog file types, run `python3 apps/ios/scripts/document-types.py --write` and
  `python3 apps/ios/scripts/test-document-types.py`.
- **Drop into Linux.** Dropped text is typed at the drop point; a dropped file or image (up
  to 50 MiB) is saved in `~/Downloads` and opened with Linux's default handler.
- **Open, share and print from Linux.** `caboose-open URL` opens a supported link on the
  phone after confirmation; Thunar's **Share to iPhone** and `caboose-share FILE` hand a file
  to the share sheet; the **iPhone** printer sends a PDF to the print dialog (10 MiB limit;
  requests wait up to 24 hours and are delivered at most once).
- **Play on iPhone or Apple TV.** When the computer's Chromium plays a video, its window's
  `…` menu moves playback to AVKit (with AirPlay), or to Safari's in-app browser for a
  stream the page builds itself; **Back to Computer** continues the computer's copy.
- **Shortcuts, Siri and Spotlight.** Shortcuts wake or park the computer, open a Linux app
  or URL, start an agent task, open, get or save computer files, and run the Craft apps'
  conversions. Spotlight indexes the computer's apps and its 200 most recently modified files.
- **Widgets and controls.** A Computer widget (state and running agents), a Favourite Linux
  App widget, and Control Center controls for power, opening an app and asking an agent.
- **Notifications and Live Activities.** With APNs configured on the host, the device can
  receive approval, finished-task and desktop alerts (approvals can be answered from the
  notification), and running agent tasks show on the Lock Screen and Dynamic Island.

## Computer settings

Home's menu, the parked screen and the failure screen open **Computer**: the computer's name,
the memory and cores it boots with (applied on the next restart), how long it waits before
parking, Park Now, Restart, and Change Computer. It uses the host's management API
(`docs/architecture.md`) and follows `computer.settings` events on the control socket.
Home's Shelf offers optional applications from the computer's pinned catalog; Library groups
them into packs and offers updates, rollback to a cached release, and removal.

The same sheet shows the progress and any failure of a guest component update the host
runs at wake. A container created without the Files port mapping shows that it must be
recreated to enable Files. The display stays usable while an update runs.

## Device checks

Behaviour that depends on a signed device, a deployed host or iOS services cannot be proved
by a simulator build. On a signed device paired to a deployed computer, check:

- **Input.** A two-finger tap opens a context menu even right after a tap; two fingers that
  move scroll without clicking; tap-tap opens a desktop file. In Chromium's address bar a
  misspelt word is corrected in place, a swiped word arrives whole, and the Japanese Romaji
  and Chinese Pinyin keyboards commit their candidates; the terminal gets no autocorrect
  until `Aa` on the key bar turns it on.
- **Share sheet.** Share a Safari page and pick Open on Computer; share a photo and pick Save
  and Open; share a photo with a request to an agent and see the task appear on Home.
- **Files.** Create a folder, save and edit a document in place and verify it on Linux;
  rename and move from each side; delete in Files and check the guest's Trash; park the
  computer and open a file to verify wake; go offline and verify Files reports the host
  unavailable without discarding an offline edit, and that a conflicting Linux edit is not
  overwritten.
- **Open in place.** Run `apps/ios/scripts/check-open-in-place.sh` and follow its checks.
- **Drops.** On an iPad, drop selected text into a Linux text editor, then an image from
  Photos and a document from Files, in both the full-screen and desktop layouts; a file over
  50 MiB shows an error.
- **Open, share and print.** Run `caboose-open 'mailto:person@example.com'` in a terminal
  and confirm only after checking the URL; share a photo from Thunar; print to iPhone. Repeat
  with the phone backgrounded: nothing happens without a tap, and queued requests arrive when
  the app opens. `guest/phone/README.md` has the scripted guest check.
- **Notifications and Live Activities.** Enable each kind, background the app, trigger an
  approval and a task completion, and use Allow and Deny from the notification; start a task
  and watch the Lock Screen and Dynamic Island update and end; start one from another client
  to check push-to-start.
- **Shortcuts, widgets and Spotlight.** Run each shortcut and check its input and output
  files; configure and tap the widgets and controls; create, rename and delete a nested file
  and check Spotlight; sign out and verify the entries disappear.
- **Shelf and Library.** Install PhotoCraft from the Shelf, follow its progress, open it, and
  remove it from Library.
