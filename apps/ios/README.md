# Caboose for iOS

The iPhone and iPad app, and **CabooseKit**, the Swift package that connects it to the
computer's display over the Caboose Display Protocol ([docs/display.md](../../docs/display.md)).

## Layout

| Path | What |
| --- | --- |
| `CabooseKit/` | Swift package, no app UI. `Session/` holds the window model the app works against (`DisplaySession`, `RemoteWindow`, the screen description, keyboard mapping). `Display/` is the protocol: canonical CBOR, framing, messages, `CabooseDisplaySession`, per-window frame pipelines, video streams and sound. `Video/` decodes H.264, HEVC and AV1 with VideoToolbox into IOSurface-backed BGRA and keeps each window's Metal surface. `Input/` has the typing buffer, trackpad gestures and touch slots. `Terminal/` is the terminal protocol: control messages, closes, the key row's sequences and `TerminalConnection`, which tracks the output offset a reattach continues from. `Switchyard/` is the tiling layout of the device's own desktop: columns on a scrolling track, widths per screen, stacks, drops and focus. `UI/RemoteWindowView` presents a window and takes touch, Pencil, trackpad and keyboard input. |
| `Caboose/` | The app: pairing, wake, the tab shell (Home, Desktop, Agents, Apps and Terminal), window screens, the desktop on this screen or a TV, agents, AirPlay, the background, settings, intents. |
| `Caboose/Terminal/` | The Terminal tab: `TerminalScreen`, the session model, SwiftTerm's view in the Caboose look and the key row above the keyboard. |
| `Caboose/Switchyard/` | The Desktop tab's tiling on the device's own screen: tiles, gaps, grabber, dock, Overview, launcher and ⌘⌥ keys, over the `CabooseKit/Switchyard` layout. |
| `Caboose/Brand/` | The logo drawn natively in SwiftUI. It shares geometry and timing with `apps/web/src/brand/brand.ts`; change both together. `scripts/render-app-icon.sh` renders the app icon from the same SVG (macOS). |
| `Share/` | The share extension (target `CabooseShare`). |
| `Files/` | The File Provider extension that shows the computer in the Files app. |
| `Widgets/`, `Shared/` | The WidgetKit extension: widgets, controls and Live Activities. |

## Build

```sh
brew install xcodegen
cd apps/ios
cp Caboose/Config/Local.xcconfig.example Caboose/Config/Local.xcconfig   # optional: pre-fill your host
xcodegen generate
open Caboose.xcodeproj
```

The Terminal tab uses [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) (MIT), whose
package runs a small build plug-in. Xcode asks once to **Trust & Enable** it; command-line
builds pass `-skipPackagePluginValidation` to `xcodebuild`.

Set your own team in `project.yml` (`DEVELOPMENT_TEAM`) to run on a device. The extensions'
bundle ids are the app's plus a suffix (`.share`, `.files`, `.widgets`). All of them sign
with the keychain group `<team>.com.braedonsaunders.caboose.shared`, through which they
share the host address and token; the app, Files and Share extensions also share the
application group `group.com.braedonsaunders.caboose`.

## Sign in

Open the console's **Phones** tab for a computer and choose **Sign in a phone**, then scan
the QR code with the iPhone's camera (or open its `caboose://connect?host=…&code=…` link on
the phone). The app trades the single-use code for its own token through `POST /v1/pair`
(`Caboose/Host/Pairing.swift`) at the first of the link's addresses that answers. The
sign-in screen also takes an address with a typed pairing code, or with a token, and older
links that carry `token=` still work. Under Computer settings, Remote Access adds or removes
alternate HTTP or HTTPS addresses without replacing the phone's token or Files identity.
The settings are available even when the host is unreachable. The app probes saved addresses
at each wake without sending a token; an anonymous health response filters captive portals but
does not authenticate the host.

## Test

```sh
cd apps/ios/CabooseKit && swift test
```

Run the remote-address unit checks and paired-phone check:

```sh
swiftc Caboose/Host/Credentials.swift tests/RemoteAddresses.swift -o /tmp/caboose-remote-address-tests
/tmp/caboose-remote-address-tests
sh scripts/check-remote-access.sh
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

The terminal's protocol, keys and connection are unit-tested over a fake transport. Against
a real host, `CABOOSE_HOST_URL=… CABOOSE_HOST_TOKEN=… swift test --filter LiveTerminal`
opens a terminal over URLSession as the app does, runs a command, resizes, reattaches from
its offset, is replaced by a second connection, exits, and checks the closes that follow.

## Checking Switchyard on a device

The layout and work-area geometry are unit-tested (`swift test --filter 'SwitchyardTests|DesktopGeometryTests|FreeDesktopLayoutTests|WindowTitleBarTests|QuickSwitchTests|DockMenuTests'`).
Run `sh scripts/check-desktop.sh` for the real-device checks, including external-display
maximizing, browser controls and app-card toolbars on Duo and ordinary iPhones. The gestures
and picture need a device with the computer awake. On the Desktop tab, with three apps open:

1. Upright iPhone: one full-width column; the side edges and the dock's cars move between
   columns, and the lit car follows. Drag a title bar to the bottom quarter of another tile: they stack.
2. Open a Duo, or turn a large phone on its side: two halves. Drag the gap: it ticks at ½ and ⅔ and settles
   on release; the apps redraw at the new width without a seam.
3. iPad: thirds, the Tiled/Free choice in the toolbar, and ⌘⌥←/→, ⌘⌥⇧←/→, ⌘⌥R, ⌘⌥O on a
   hardware keyboard (hold ⌘ to see them listed). Plain ⌘C still copies in the app.
4. Open a menu and a dialog in a tile: both appear over that tile. Park and wake: the same
   columns come back.
5. Every tile has a title bar above its app, with red Close and green Full Screen at its
   leading edge: the app's own top row (tabs, menus, address bar) is whole below it, and
   a menu opened from that row lands where it was tapped. Tap a tile to focus it, then use
   the trailing toolbar's Full Screen control; double-tap the title, press the green
   button, use the ••• menu, or press ⌘⌥F: the same app card as
   Apps opens. Close the card: Desktop and its tile layout return. Rotate/fold while
   the card is up, hide/show its controls, then dismiss: both card and desktop fit their
   available viewport. Browser content keeps its own double taps. Two fingers tapped on a
   window right-click, with a ring where they landed. On Duo, swipe inward from the bar
   edge to reveal the wallpaper-backed native controls; swipe outward starting on a control
   or use Hide window controls to dismiss them. Check both edge placements, VoiceOver,
   keyboard and Return, and repeat after folding and rotating.
6. iPad set to Free, and a TV: drag a title bar to the left edge, a corner and the top
   edge; an outline shows each snap and letting go takes it. Drag the window back out: it
   returns to its own size under the finger. Drag one window beside another: their edges
   meet. Arrange three windows, rotate, rotate back: every window is where it was. Relaunch
   the app: the same places. Close a window and open the app again: it gets a fresh place.
   Under a finger, Close, Minimize and Zoom show their symbols and each takes a tap at the
   bar's full height. ⌘⌥←/→/↑/↓ bring the nearest window forward; ⌘⌥⇧←/→ snap, ⌘⌥⇧↑
   maximizes, ⌘⌥⇧↓ restores.
7. With a hardware keyboard and three windows, on Tiled, Free and a TV: ⌥Tab and let go
   returns to the previous window. Hold ⌥ and press Tab repeatedly: the strip on the
   leading edge moves its selection with the app and title beside it, and the desktop shows
   each window; ⇧ goes back; letting go of ⌥ lands there; Escape stays. Tap a window in the
   open strip. Close a window while the strip is open: it leaves the strip.
8. Without a keyboard, on an upright iPhone, a Duo and an iPad (Tiled): tap Overview, and
   Overview opens. Hold Overview until the strip appears, slide up the screen: the window
   level with your finger is selected, named beside it, and the track slides to it while the
   apps keep their size and place. Let go on a row: that window is focused. Hold again and
   let go back on the dock: nothing changes, and Overview does not open. With more windows
   open than the strip shows, slide slowly up and down it: the rows never move under the
   finger. With VoiceOver,
   Overview's actions include Switch Windows; choose a window or Stay Here. On iPad Free, do
   the same holding Launchpad. On a TV, two-finger tap Launchpad on the phone's trackpad,
   then tap a row or Stay Here. While a strip is open, background the app, open a card, or
   lose the connection: the strip closes and nothing moves.
9. On a Duo (tiled, opened and folded), an upright iPhone and an iPad: tap a dock app; it
   opens or goes to its window. Hold a dock app: a menu offers Open, Pin or Unpin, and Close
   for each of its windows by title; each does what it says, for a running app and for a
   pinned one that is not running. A swipe up on the dock still opens Overview. On iPad Free
   and a TV, hold (or secondary-click) a dock app for the same actions.

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
  The base picture and video clips share the confirmed surface-to-view mapping during
  resizing; the outer Yard transform applies to both once. Only the active presentation
  owns the playback layer. `VideoLayerGeometryTests`, `VideoSessionTests` and
  `TapTextFocusTests` cover geometry, repaint retirement and keyboard decisions on macOS;
  `VideoLayerHostingTests` exercises layer transfer when running the package tests on iOS.
  `scripts/check-desktop.sh` covers real-device video, fullscreen exit and editing gestures.
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
event is one touch frame, so pinch and swipe are the app's own. A two-finger tap or a
stationary half-second hold cancels that native touch sequence and sends a right-click, with a brief ring and haptic.
Apple Pencil is a
tablet with pressure, tilt and azimuth on every coalesced sample, and hover on iPads that
have it. X11 windows (through Xwayland) take pointer gestures, since X11 apps turn a touch
drag into a selection: swipe scrolls with momentum, tap clicks, double-tap double-clicks, a
two-finger tap or a stationary half-second hold right-clicks immediately, and tap then
hold and move drags. Individual pointer taps retain their timing for double-clicks. A trackpad or
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

## Terminal

The Terminal tab is a native terminal on a shell in the computer, not a streamed window. It
uses [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) (MIT), pinned in `project.yml`:
the maintained Swift terminal emulator, with truecolor, selection, OSC 8 links and hardware
keyboards on iOS. Caboose uses its Core Graphics renderer so default cells remain transparent
over the terminal background; explicit ANSI backgrounds remain visible. Its look, key row, gestures, reattach and session menu
are in `docs/architecture.md` § 6 Terminal.

## Agents

The Agents tab is a chat with an agent on your computer. A chat is one of the computer's
agent tasks: the first message starts it with the default agent (or the one picked in the
composer's menu), and everything after is the next turn of the same session, so the agent
always has the whole conversation. Send while it is working and the message waits for its
turn to end, shown as waiting with **Send Now**, which stops the turn and sends it at once.
**New Chat** starts a fresh session; the chat list holds the rest, and other chats still
working are pinned along the top. Where Apple Intelligence is available, the on-device model
names each chat from its first message (`ChatTitler`); nothing you say goes through it.

The chat shows what the agent does as it does it (`AgentThreadView`, folded by
`AgentThread` in CabooseKit): its answers, collapsible thoughts, tool calls, its plan as a
checklist, the permissions it asked for, and how much context it has used, read from the
host's transcript route and then live. Stop it, watch its window on the agent seat, or ask
another agent the same thing in a new chat. **Ask Before Acting** makes the agent stop
before each action until you tap Allow (or its always-allow option) or Deny, in the chat, on
Home or on the banner over any screen. **Use Craft App Tools** controls whether new chats
offer installed catalog MCP servers to the agent.

**Connect a Model** uses an API key instead of an account: an OpenRouter key and any of its
tool-using models (run by the registry's goose), or an Anthropic or OpenAI key (Claude Agent
or Codex). The app installs the agent, puts the key in its environment in the computer, and
makes it the default. A chat whose agent is signed out offers **Sign In** and **Ask
Another** (another agent, or Connect a Model). Settings › Agents installs and updates any
registry agent, signs in to them, edits their environment, and sets the default.

Signing in happens on the phone (`AgentSignInView`). The computer runs the agent's own
sign-in, but its page opens in a private browser in the sheet; when the page sends you back
to the computer's localhost, the app hands that address to the agent on the computer, so a
ChatGPT or similar login finishes without touching the computer's screen. A sign-in that
runs in a terminal, such as Claude's, shows that terminal in the sheet to answer its prompts
(the Terminal tab's view, pinned to that one session). Google accounts refuse to sign in
inside an app's browser, so use another option the page offers, or **Sign In on Computer's
Screen** from the sheet's menu. Each sheet follows only the sign-in attempt it started:
leaving it before it finishes cancels that attempt, and if a newer sign-in to the same agent
starts (from another sheet or device), the sheet says so and stops, never touching the newer
one.

Agents run their GUI apps on the agent seat, a second display of the computer. The app
connects to it as it does to the owner's display (`/v1/display?seat=agent`, without sound);
watch its windows from the chat, take over and hand back. A window's `…` menu has **Ask
Agent About This Window**, which sends its screenshot, title and app with your request.

On a device paired to a running computer, check: start a chat, then send "how's it going?"
while the agent works and see it wait and go with the next turn; tap Send Now and see the
turn stop and the message go at once; open the chat list and switch chats; connect an
OpenRouter key and see goose become the default and answer.

## iOS integration

- **Share sheet.** A web page opens in the computer's browser; photos, files and text are
  saved in `~/Downloads` (and opened there) or handed to an agent with a request (photos
  scaled to 2048 px, at most 4 files and 10 MB).
- **Files.** The paired computer is a Files location named after the computer: browse its
  home, download on demand, create folders, edit in place, rename, move and delete. A parked
  computer wakes for file access. Setup runs independently of wake; Computer settings
  shows Files registration errors and offers Retry Files Setup. Run
  `python3 scripts/check-file-provider.py` for source metadata, or add `--app /path/to/Caboose.app`
  to verify the signed package. `python3 scripts/test-file-domains.py` tests delayed registration,
  switching, failure, retry and sign-out ordering. `sh scripts/check-files.sh` prints the
  real-phone verification steps.
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

## Home and the tabs

Home is Today: the computer's name and how it is, with the one action that fits (Turn On,
Try Again, Show Here); its windows in the order they were last used, live, each opening full
screen on a tap; approvals the agents are waiting on, answered in place; agents at work;
what finished and changed since the app last left the screen (agent turns that succeeded or
failed, and new files outside hidden folders), or the newest files when nothing is new; and
pinned apps. While the computer is parked, waking or out of reach, the window strip shows
each window's last picture, dimmed, taken as the app leaves the screen and as the computer
parks, kept in Caches per computer, and forgotten once the running computer has no windows.
They are pictures only: a tap turns the computer on, and the live windows take their place
once it is back. The toolbar has AirPlay beside the Computer pair.

Ask opens windows, apps and the home's files by name (every word must start a word of the
name, ignoring case and accents; windows first, then apps, then files) and, with an agent
available, hands what was typed to the default agent as a new chat. Return takes the first
row.

On an iPhone whose bars are horizontal, the tabs sit at the bottom right instead of the
system's bar across the bottom: a glass cluster beside Ask when the phone is upright, and a
sidebar down the trailing edge with the tabs at its foot once the screen is 600 points wide
(an iPhone Duo opened out, or any phone on its side). The cluster goes under the software
keyboard, as the system's tab bar does; the sidebar stays, its tabs riding above the
keyboard, as the system's vertical bar does. Both step aside for a window covering the
Desktop. Where the system
draws its vertical bar (iPhone Duo, iOS 27.1), and on iPad, the system's tab bar is used.

## Computer settings

The cog in every tab's toolbar opens **Computer**: the computer's name, the memory and cores
it boots with (applied on the next restart), how long it waits before parking, Park Now,
Restart, the wallpaper, and Change Computer. Beside the cog, the lifecycle menu shows the
computer's state and offers Turn On, Park and Restart as they apply. Both use the host's
management API (`docs/architecture.md`) and follow `computer.settings` events on the control
socket. The Apps tab's Shelf offers optional applications from the computer's pinned
catalog and Debian's AppStream metadata. Library searches Debian applications, filters results by category, labels Caboose picks as curated, groups curated apps into packs, and offers updates, rollback to a cached release, and removal.

The wallpaper lies behind every tab and the desktop, here and on a TV: the brand gradient,
photographs that change every quarter hour, one photograph, or a picture of your own from
Photos. Choose it in Computer settings, from the Desktop's overflow menu, or with a long
press on Home's background.

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
  until Autocorrect in the keyboard controls menu turns it on.
- **Share sheet.** Share a Safari page and pick Open on Computer; share a photo and pick Save
  and Open; share a photo with a request to an agent and see the task appear on Home and in Agents.
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
- **Tabs and the vertical bar.** On iPhone Duo, closed and open in landscape, every tab's
  bar is on the side with the tabs, the cog and the lifecycle menu; on the Desktop tab the
  desktop fills the space beside the bar and resizes when the device folds or rotates; on a
  phone without the bar the toolbar is horizontal and the tabs are a cluster at the bottom
  right beside Home's Ask, or a sidebar on the trailing edge on a Duo opened out or a phone
  on its side; the cluster hides under the keyboard, the sidebar's tabs stay above it, both
  hide behind a full-screen Switchyard window, and Agents shows its approval count. Open the Desktop's
  Launchpad on the closed phone and check that it and the dock fit. Capture either display
  with `xcrun devicectl device capture screenshot --display-unique-id <id>` (ids from
  `devicectl device info displays`); `caboose://home`, `desktop`, `agents` and `apps`
  select a tab.
- **AirPlay.** With an AirPlay device in reach, play to it once from the route picker in
  Home's AirPlay sheet; the sheet then names it, and its main control reconnects or offers
  it as the Automatically AirPlay setting allows. Park, Turn On and Restart from the
  lifecycle menu.
- **Home.** With three apps open, Home's strip shows them live, most recently used first,
  and a tap opens each full screen. Background the app, then park from Computer settings on
  return: the strip shows the dimmed pictures; tap one and the computer wakes, and the live
  windows replace them. Close every app and leave: the pictures do not come back.
  Start an agent task, leave the app until it ends, and come back: it is under Since You
  Left. In Ask, type part of an app's, window's and file's name, open each, and send a
  request to the default agent.

## Agent conversations

The Agents tab has a native composer for camera, Photos, Files and explicit speech
recognition. Unsent input stays with each chat while the app is open; failed sends keep
its text and files. Responses use the host's live draft snapshots and transcript events,
with native markdown blocks, selectable code and Copy. Tool progress and approvals appear
inline, and an existing agent-seat window has a live preview and Watch action.

Run `scripts/check-agents.sh` for the real-device checklist against a matching host. It
covers streaming, same-named queued attachments and Send Now, approvals, seat takeover,
speech permissions, failed sends and chat switching. No scheduled-task or cross-agent
memory feature is implied by the composer; conversation continuity belongs to the ACP agent.

### Shared keyboard controls

App cards, Desktop, the display trackpad, Terminal, Agents and app-owned native
form fields use CabooseKit's `KeyBar`. `Caboose/NativeTextInput.swift` bridges UIKit
text editing into SwiftUI, retaining marked text, selection, paste, secure entry and
Dynamic Type. Its multiline fields grow to their line cap, then scroll. Native Ctrl/Alt apply to the next key, including word navigation. Ctrl+A/C/X/V/Z/Y
use native Select All, Copy, Cut, Paste, Undo and Redo; secure fields block Copy/Cut.
Unsupported chords announce their unavailability without inserting text or control bytes. Composer Send
and Hide clear focus; rendering and send completion do not reopen the keyboard. A tap,
suggestion or Ask shortcut explicitly requests it again. The agent sign-in sheet uses
translucent material over the presenting screen.
Hide Keyboard stays fixed at the right edge of the single keyboard header row on iPhone,
Duo and iPad; the keys do not scroll. Remote inputs share `RemoteTextInputView` for
composition, autocorrect and sticky modifiers. Terminal adapts the same accessory
to SwiftTerm's cursor modes and byte protocol. Verify folded/unfolded/rotated layouts,
Hide and reopening, Ctrl/Alt, held arrows, Return and IME with `scripts/check-desktop.sh`.

Check native text entry with `scripts/check-agents.sh`; this includes keyboard focus,
IME and selection, native form traits and the sign-in sheet material.

The Agents toolbar's Model sheet reads available models from the computer's ACP agent.
New chats pass the selected provider model with task creation; idle chats can choose the
model for their next message. The sheet shows the current model separately until the
agent confirms the requested selection. Model discovery may require agent sign-in.

Each desktop tile has a visible Close Window button. Hold a dock icon for Open, Pin/Unpin
and Close actions. Chat turns stay mounted while sending and changing keyboard height;
stale transcript reads retain completed answers already shown.


## Checking chat artifacts on a device

Pure parser/path/sandbox policy checks run with `swift test --filter 'ChatArtifactTests|ChatMarkdownTests'`
in `CabooseKit`. In an agent chat, generate a PDF and PNG beneath `/home/caboose/Agents/<task>/artifacts`
and return Markdown links plus standalone image Markdown. Tap the PDF and image: both show
Quick Look and Share; save a copy to Files. A missing file shows an error; a file above 25 MiB
fails without finishing its download. Guest `file://` links use the computer's file service.
Traversal and files outside the computer home never open on the phone.

Return a complete fenced `inline-html` block with an inline SVG chart, a button that changes
it, a growing/shrinking section and a CSS animation. Check touch, VoiceOver labels, rotation,
Full Screen, Done and HTML export. Change a widget control, open it full screen, then use
Done: its interactive state must survive both moves and the view must fit after rotation.
Append prose after the fence while streaming: the
widget retains its interactive state. Incomplete HTML shows a completion placeholder,
never source; an oversized widget shows a size message. A failed preview offers Try Again
without showing HTML. External script/image,
fetch, WebSocket, navigation, popup and `file://` attempts must fail; self-contained data images
and inline scripts/styles work. A widget button calling `window.Caboose.compose("Explain this chart")`
shows a native proposed-message sheet; Cancel changes nothing, and Use in Composer fills the
draft without sending. Calls without user activation or above 32,000 characters do nothing.
The bridge requires a recent touch; keyboard-only activation is not supported.

Quick Look, WebKit isolation, actual file download/share, touch and VoiceOver require the app
on a device; unit tests cover the pure policy and fence parsing.

The shared keyboard header is one 48-point row with plain keys on the system keyboard
surface. Its controls menu selects Keys, Move or Symbols and exposes every action plus
Autocorrect. Groups show four keys at compact widths and six from 378 points wide; Hide
Keyboard stays fixed at the right edge. Hold Home or End for page navigation and symbol
keys for related punctuation, also available in the menu. Group changes retain active
Ctrl/Alt modifiers, indicated on the controls menu even when their keys are hidden.
Verify the header in Terminal, desktop apps and Agents at narrow width and with the Duo
sidebar: all controls stay in one row, Hide remains reachable, held arrows repeat and
VoiceOver activates an arrow once. Check every group, menu alternatives and Autocorrect.

For dock and toolbar verification on the Duo: hold both a pinned app icon and a running
column icon. Each running window offers Open and Close, and a known application offers
Pin or Unpin. A stacked column lists each window separately. A normal tap still focuses
its column and dragging the column strip still scrolls the desktop. In Agents, only the
system overflow remains; Stop, Copy Answer and Connect a Model join its regular actions.
Open the power control and confirm its popover appears beside that control on both Duo
screens. Dismiss it without parking or restarting when checking placement only.

## Laptop mode

Desktop and full-screen app cards offer Screen Layout → Automatic, Tablet or Laptop.
Automatic uses a partially folded horizontal hinge on iOS 27.1 and later. Laptop also
works as a manual split on a sufficiently tall flat screen. The upper area shows the
app/desktop without the system toolbar. The lower-right control rail offers Keyboard,
Trackpad or Combo, window switching, full screen, settings, power and navigation. Keyboard
and Combo use the same system keyboard and single-row KeyBar used elsewhere; Hide Keyboard
returns to the trackpad. The rail stays above the native keyboard. The upper desktop uses
floating windows with a dock; its pointer reaches both the app and desktop controls. Tablet
mode retains its saved arrangement. One-finger movement, tap/double-tap, two-finger
scroll/right-click and tap-then-drag use the existing trackpad gestures. With a connected
monitor, the phone shows window previews above its keyboard/trackpad and leaves the monitor's
workspace intact. Book posture and compact screens keep the ordinary layout in Automatic.

Run `sh apps/ios/scripts/check-laptop.sh` for the physical Duo, keyboard and monitor checks.
Pure fold/keyboard geometry is covered by `swift test --filter LaptopLayoutTests` in CabooseKit.
