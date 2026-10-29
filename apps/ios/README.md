# Caboose for iOS

The iPhone and iPad app, and **CabooseKit**, the Swift package that connects it to the
computer's display over the Caboose Display Protocol ([docs/display.md](../../docs/display.md)).

## Layout

| Path | What |
| --- | --- |
| `CabooseKit/` | Swift package, no app UI. `Session/` holds the window model the app works against (`DisplaySession`, `RemoteWindow`, the screen description, keyboard mapping). `Display/` is the protocol: canonical CBOR, framing, messages, `CabooseDisplaySession`, per-window frame pipelines, video streams and sound. `Video/` decodes H.264, HEVC and AV1 with VideoToolbox into IOSurface-backed BGRA and keeps each window's Metal surface. `Input/` has the typing buffer, trackpad gestures, touch slots and the on-screen controller (`OnScreenGamepad`: its types, layouts and touch tracking). `Terminal/` is the terminal protocol: control messages, closes, the key row's sequences and `TerminalConnection`, which tracks the output offset a reattach continues from. `Switchyard/` is the tiling layout of the device's own desktop: columns on a scrolling track, widths per screen, stacks, drops and focus. `Game/` runs games the computer hands off ([game handoff](../../docs/game-handoff.md)): `RemoteGame` and declining a game the device cannot run, `GameServer`, the loopback HTTP origin a game's page loads from, with its file cache, save sync, the page's IndexedDB and gamepad scripts, and `GameSurfaceView`, the web view a window's game runs in. `UI/RemoteWindowView` presents a window and takes touch, Pencil, trackpad and keyboard input, and lays a window's game over its picture. `GPU/GPUStreamPlayer` and `UI/GPUStreamView` replay a window's GPU stream ([GPU streams](#gpu-streams)). |
| `GPUStream/` | The GPU stream player's native side: a C API (`include/caboose_gpu_stream.h`) over GFXReconstruct's Vulkan replay, the CMake project that builds it with MoltenVK, and the patches applied to GFXReconstruct. See [GPU streams](#gpu-streams). CabooseKit's `GPU/GPUStreamPlayer` and `UI/GPUStreamView` wrap it. |
| `Caboose/` | The app: pairing, wake, the tab shell (Home, Desktop, Agents, Apps and Terminal), window screens, the desktop on this screen or a TV, agents, AirPlay, the background, settings, intents. |
| `Caboose/Catalog/`, `Caboose/McpLibrary/` | The Apps tab's Library (`CatalogCenter`, `CatalogViews`) and the Agents tab's Tools, the MCP Library (`McpCenter`, `McpLibraryViews`). Both storefronts draw with `StoreChrome`: the icon well, rows of tiles with See All, tiles and list rows. The MCP Library's routes, answers and setup form are `CabooseKit/Catalog/McpLibrary`. |
| `Caboose/Terminal/` | The Terminal tab: `TerminalScreen`, the session model, SwiftTerm's view in the Caboose look and the key row above the keyboard. |
| `Caboose/Switchyard/` | The Desktop tab's tiling on the device's own screen: tiles, gaps, grabber, dock, Overview, launcher and ⌘⌥ keys, over the `CabooseKit/Switchyard` layout. |
| `Caboose/Brand/` | The logo drawn natively in SwiftUI. It shares geometry and timing with `apps/web/src/brand/brand.ts`; change both together. `scripts/render-app-icon.sh` renders the app icon from the same SVG (macOS). |
| `Share/` | The share extension (target `CabooseShare`). |
| `Files/` | The File Provider extension that shows the computer in the Files app. |
| `Widgets/`, `Shared/` | The WidgetKit extension: widgets, controls and Live Activities. |

## Build

Building needs **Xcode 27.1 or later** (the iOS 27.1 SDK); the app itself runs on iOS 26.
The fold-aware Laptop layout (`UIHingeInteraction`, `reservedRegions(kind:)`) and the
vertical tab bar and toolbar (`toolbarVerticalEdge`, `ToolbarOverflowMenu`,
`visibilityPriority`) are iOS 27 API behind `#available(iOS 27, *)` checks, which only
compile against that SDK; on iOS 26 those paths are skipped at run time.

```sh
brew install xcodegen
cd apps/ios
cp Caboose/Config/Local.xcconfig.example Caboose/Config/Local.xcconfig   # optional: pre-fill your host in Debug builds
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

Opted-in agent apps use a native WebKit view and the authenticated guest bridge, with a
stable per-app origin. Apps that depend on computer-side browser storage stay on the
computer; the `handoff: "files"` contract and fallback are in
[guest/apps](../../guest/apps/README.md#native-handoff).

The unit tests replay the compositor's golden vectors from `guest/display/vectors` (every
message decodes, re-encodes byte for byte and parses, and every client message the app
sends matches its vector), drive `CabooseDisplaySession` over a mocked transport
(handshake, windows, acks and keyframe recovery, vsync, input, text and preedit, sound,
and reconnecting: epoch-checked window resume, the post-hello announcement marker, stale
streams and pipelines, the watchdog, the retry policy and the measured metrics, and game
handoff: `game.create` and `game.destroy`, games kept across a resume, saves flushed before
`close` and before `game.decline`, declines sent once per connection and only for its announced current game, and no
input to a game window reaching the computer), check the game rules (path resolution,
ranges, content types, the cache and its eviction, conflict names, the save planner and
save sync against an in-memory file service), check the game's loopback origin (request
parsing and its bounds, the token, `Host` and method checks, response headers, and
`GameServer` fetched over 127.0.0.1 with URLSession, closing its connections when it stops
or when a request does not arrive), run the game page's IndexedDB and
gamepad scripts in JavaScriptCore the way Emscripten's IDBFS and a Gamepad API poll use
them, and decode the vectors' H.264 and HEVC keyframes and an AV1 stream
(`Tests/CabooseKitTests/Fixtures`) in hardware. The AV1 test runs where the Mac has an AV1
decoder (M3 and later).

The native agent-app handoff has a focused simulator check using a local fake host:

```sh
SIMULATOR_ID=<available-ios-simulator-udid> sh scripts/check-agent-app-webview.sh
```

It exercises the real WKWebView, injected API, idle event polling, reload and takeover.
The check uses port 18765 on loopback and an unchanged temporary package copy.
Builds without MetalFX use the software motion upscaler. Select the full Xcode
developer directory before running the check.

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

The MCP Library's routes (a qualified name's one `/` kept as a separator, every other
character of a segment encoded, 1-based search pages and where paging stops), its answers
(every connection status, sign-in pages limited to https on smithery.ai) and the setup form
(required settings, only the keys the server declared) are unit-tested in `McpLibraryTests`.

The terminal's protocol, keys and connection are unit-tested over a fake transport. Against
a real host, `CABOOSE_HOST_URL=… CABOOSE_HOST_TOKEN=… swift test --filter LiveTerminal`
opens a terminal over URLSession as the app does, runs a command, resizes, reattaches from
its offset, is replaced by a second connection, exits, and checks the closes that follow.

## Checking Switchyard on a device

The layout and work-area geometry are unit-tested (`swift test --filter 'SwitchyardTests|DesktopGeometryTests|FreeDesktopLayoutTests|WindowTitleBarTests|QuickSwitchTests|DockMenuTests'`).
Run `sh scripts/check-desktop.sh` for the real-device checks, including external-display
maximizing, browser controls and app-card toolbars on Duo and ordinary iPhones. The gestures
and picture need a device with the computer awake. On the Desktop tab, with three apps open:

1. Upright iPhone: one full-width column; the side edges and Overview move between
   columns, and the lit car follows. Drag a title bar to the bottom quarter of another tile: they stack.
2. Open a Duo, or turn a large phone on its side: two halves. Drag the gap: it ticks at ½ and ⅔ and settles
   on release; the apps redraw at the new width without a seam.
3. iPad: thirds, the Tiled/Free choice in the toolbar, and ⌘⌥←/→, ⌘⌥⇧←/→, ⌘⌥R, ⌘⌥O on a
   hardware keyboard (hold ⌘ to see them listed). Plain ⌘C still copies in the app.
4. Open a menu and a dialog in a tile: both appear over that tile. Park and wake: the same
   columns come back. Open a fixed-size dialog (such as a keyring prompt) as an app card:
   it keeps its aspect ratio, tapping Cancel lands on Cancel, and rotating the phone does
   not stretch the dialog or move its touch targets away from the visible controls.
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
- **Video in windows.** The app leaves passthrough streams to server decoding. It requests
  half-resolution software-encoded motion streams and upscales them using MetalFX or vImage
  on the CPU. If both fail, the video layer scales the decoded picture. Resize metadata retains the previous
  picture's pixel basis until its replacement frame decodes.
  `VideoLayerGeometryTests` and `VideoSessionTests` cover geometry, negotiation and
  retirement; `scripts/check-desktop.sh` covers physical-device playback and resizing,
  and `scripts/check-scaled-motion.sh` checks scaled motion and device fallback.
- **Sound.** The computer's sound arrives as 20 ms Opus packets on the server timeline,
  decoded by AudioToolbox and played by an `AVSampleBufferAudioRenderer`. Playback uses
  an explicit monotonic host/server anchor, with decoded sample durations keeping nearby
  packets contiguous despite capture-timestamp jitter. Gaps over 200 ms reanchor to the
  server. Playback starts 120 ms behind the first packet; a late packet adds 20 ms (up to
  240 ms). A rolling sample-clock estimate adjusts playback speed with pitch preservation;
  drift does not flush queued sound. A backlog beyond another 300 ms is dropped. Interruptions reset the anchor. The display closes
  when the app goes to the background, and the sound with it.
- **One device at a time.** The computer's display shows on one device. When another takes
  it, this one gets `bye { reason: "replaced" }`, says it is showing on another device, and
  does not reconnect on its own; Show Here takes it back. A ping every 5 s keeps the server
  from closing the session as idle.

## GPU streams

A window whose application renders through Vulkan can arrive as a GPU stream instead of
video ([docs/gpu-stream.md](../../docs/gpu-stream.md)): the GFXReconstruct capture of its
Vulkan calls, which the device replays on its own GPU. `GPUStreamPlayer` takes the stream's
bytes in order and reports each frame, the bytes it has taken (the offset `gpu.ack`
reports) and how the replay ended; `GPUStreamView` is the `CAMetalLayer` it presents into.

The player is [GFXReconstruct](https://github.com/LunarG/gfxreconstruct) (MIT), tag
`vulkan-sdk-1.4.363.0` (capture format 1.0.5, the capture layer the computer runs), and
[MoltenVK](https://github.com/KhronosGroup/MoltenVK) (Apache-2.0) 1.4.2, the MoltenVK of the
same SDK. It replays the way `gfxrecon-replay --remove-unsupported -m rebind` does:
extensions and features the device lacks are removed, memory is rebound to the device's
memory types, and presents go through GFXReconstruct's virtual swapchain into the layer.
`GPUStream/src/player.mm` runs GFXReconstruct's `FileProcessor` and `VulkanReplayConsumer`
on a thread with an 8 MiB stack, reading the fed bytes from a FIFO in the app's temporary
directory, so a stream that arrives faster than it replays waits in the feed.
`GPUStream/src/layer_window.mm` is GFXReconstruct's `MetalContext` with windows that are
layers: the first live surface presents into the view's layer, and further surfaces the
application makes at the same time render into layers that are not shown. GFXReconstruct
finds MoltenVK through `GPUStream/patches/0001-replay-instance-proc-addr.patch`, which lets
replay use a `vkGetInstanceProcAddr` linked into the app instead of loading a Vulkan library.

The native code is a build product, not checked in (it is about 40 MB per platform):

```sh
sh scripts/build-gpu-stream.sh                    # macos, ios and ios-simulator slices
sh scripts/build-gpu-stream.sh macos              # just the one swift test uses
```

It fetches GFXReconstruct by commit and the MoltenVK release by SHA-256, builds with at most
`JOBS` (default 4) compiles at a time, and writes
`CabooseKit/Frameworks/CabooseGPUStream.xcframework` (arm64 macOS, iOS and iOS simulator)
and both licences in `CabooseKit/Frameworks/Licenses`. It needs Xcode (set `DEVELOPER_DIR`
if `xcode-select` points at the Command Line Tools), CMake 3.24 or later and Ninja. A first
build takes about 20 minutes per slice. `Package.swift` links the xcframework when it is
there; without it CabooseKit builds without `GPUStreamPlayer` and `GPUStreamView`
(`#if canImport(CabooseGPUStream)`), so build it before `xcodegen generate` for an app that
plays GPU streams. Ship the two licences with the app's acknowledgements.

With the xcframework built, `swift test --filter GPUStreamPlayer` checks the player's ends
(an empty stream, bytes that are not a capture, stopping, one replay at a time). Replay a
real capture through MoltenVK into a layer on no screen with

```sh
CABOOSE_GPU_CAPTURE=~/cube.gfxr CABOOSE_GPU_CAPTURE_FRAMES=300 swift test --filter GPUStreamPlayer
```

which requires every frame to replay without an error and prints the frame rate. A capture
of `vkcube --use_staging` against the Khronos mock driver (`GFXRECON_CAPTURE_FILE=cube.gfxr`,
`GFXRECON_CAPTURE_COMPRESSION_TYPE=NONE`, `VK_INSTANCE_LAYERS=VK_LAYER_LUNARG_gfxreconstruct`)
has 300 frames.

`GPUDeviceCapabilities.queryJSON()` reports capabilities from the MoltenVK linked into
the running app, without creating a Vulkan device or surface. It returns schema-versioned
JSON with every physical device's core features, relevant limits, extension versions and
all sixteen BC formats' sampled-image support, including the image-format query result.
The query does not alter the guest profile. Rebuild the xcframework after changing this
native API; an older binary lacks its symbols.

The opt-in real-device check writes a report and verifies that an advertised BC feature
agrees with all BC formats' sampled-image support. Run from `CabooseKit` after building
the macOS slice:

```sh
CABOOSE_GPU_CAPABILITIES=/tmp/caboose-gpu-capabilities.json swift test --filter GPUDeviceCapabilities
```

For evidence from a signed iOS app, call the same API in the app process on that device,
off the UI thread, and save the returned data to an app-accessible diagnostic file:

```swift
let report = try await Task.detached { try GPUDeviceCapabilities.queryJSON() }.value
try report.write(to: diagnosticURL, options: .atomic)
```

A simulator or macOS report describes that host's GPU, not the phone. The report is a
feature query, not a rendering test or a complete Khronos profile. Game compatibility
still requires a real replay with the reported features.

The signed Debug app has an opt-in launch diagnostic. With the rebuilt GPU framework
installed, launch it with `CABOOSE_GPU_CAPABILITIES=1` in the app's environment:

```sh
xcrun devicectl device process launch --device "$DEVICE" --terminate-existing \
  --environment-variables '{"CABOOSE_GPU_CAPABILITIES":"1"}' com.braedonsaunders.caboose
xcrun devicectl device copy from --device "$DEVICE" --domain-type appDataContainer \
  --domain-identifier com.braedonsaunders.caboose \
  --source Library/Caches/CabooseDiagnostics/gpu-capabilities.json \
  --destination /tmp/caboose-phone-gpu-capabilities.json
```

Wait for the background query to finish before copying. Each requested run removes the
previous report first, so a failed query cannot leave old evidence in its place. The
hook is absent from Release builds and does nothing on an ordinary launch.

- **One stream at a time.** GFXReconstruct's decoder keeps process-wide state, so one player
  replays at a time; a player started while another replays waits until that one stops.
- **Compression.** Streams are uncompressed or zlib-compressed; LZ4 and Zstd blocks end the
  replay with an error.
- **Fatal replay errors.** A Vulkan call that cannot be replayed ends the replay with
  GFXReconstruct's message. A few of GFXReconstruct's checks abort the process instead (no
  usable surface extension at all, for example); MoltenVK always provides
  `VK_EXT_metal_surface`.

## How input works

Native Wayland windows take real multi-touch: every finger is a touch slot and each UIKit
event is one touch frame, so pinch and swipe are the app's own. A two-finger tap or a
stationary half-second hold cancels that native touch sequence and sends a right-click, with a brief ring and haptic.
Apple Pencil is a
tablet with pressure, tilt and azimuth on every coalesced sample, and hover on iPads that
have it. Mouse-only windows, including X11 apps through Xwayland, take pointer gestures:
one finger scrolls with momentum. Hold for half a second, feel the haptic, then move to
select text or drag a control with the primary button; lifting releases it. Two fingers
also scroll. A tap clicks, two quick taps double-click, and a two-finger tap right-clicks.
Pencil strokes and hardware pointers drag directly. A held drag releases its button on
cancellation, target change or backgrounding. The free desktop uses the same content
pan/hold gestures; window title bars and resize handles still drag immediately. These rules are shared by
all mouse-only windows, with no application-name overrides. A trackpad or mouse hovers,
clicks and right-clicks precisely.

Emulated scrolling shares `CabooseKit/Input/ScrollPhysics.swift`: fractional deltas are
coalesced once per display frame, and release velocity decays independently of refresh
rate. Desktop content scrolling and the phone trackpad use the same inertia. New
input, context actions, leaving the surface, losing the target and backgrounding stop
client inertia; native Wayland touch keeps the application's own fling behavior.
Run `swift test --filter ScrollPhysicsTests` in `apps/ios/CabooseKit` for deterministic
checks of distance at 30/60/90/120 Hz, fractional input, cancellation, stale release,
reversal and display stalls. On a real host, check slow and fast swipes in a native
Wayland app and one- and two-finger swipes in an Xwayland app, then desktop/trackpad scrolling. Confirm
that a new touch stops the fling, a held finger stops before release, pinches still
zoom, drawing and selection still work, context clicks do not fling, and changing
windows or backgrounding never sends old scroll input to the next window.


With the desktop on a TV the phone is its input, with the same choices as Laptop from the
input button in its header: Trackpad, Keyboard & Trackpad, Keyboard and Gamepad. Keyboard &
Trackpad and Keyboard are Laptop's own keyboard and shortcut header; the keyboard button over
the plain trackpad opens the system keyboard instead, and the globe key does too from Laptop's
keyboard, which returns when it is hidden. Gamepad fills the whole phone, in either
orientation, with the [on-screen controller](#on-screen-controller) and a button that returns
to the trackpad. As a trackpad, one finger moves the cursor, tap clicks,
two fingers scroll, a two-finger tap right-clicks, two quick taps double-click and tap then
touch and move drags. Those rules live in `CabooseKit/Input/TrackpadGestures.swift` and are
unit-tested with staggered fingers, because real fingers never land or lift together.

The iOS keyboard types through `UITextInput` (`CabooseKit/UI/RemoteTextInputView.swift`),
and `CabooseKit/Input/TypingBuffer.swift` turns its edits into text-input commits and
deletions, unit-tested for autocorrect, swipe words, marked text and deletes. The keyboard
opens from the app's own text-input state or text cursor. An unclassified Xwayland bitmap
cursor uses the delayed legacy opening fallback. Tapping again does not dismiss an
already-open keyboard; use its dismiss control. The field's purpose turns autocorrect off in
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
host's transcript route and then live. Stop it or watch its window on the agent seat.
**Switch Agent** selects the recipient of a new chat without sending anything or replaying
the previous request. The previous conversation and its unsent draft remain in Chats. **Ask Before Acting** makes the agent stop
before each action until you tap Allow (or its always-allow option) or Deny, in the chat, on
Home or on the banner over any screen. **Use Craft App Tools** controls whether new chats
offer installed catalog MCP servers to the agent.

**Agent Settings → Connect a Model** uses an API key instead of an account: an OpenRouter key and any of its
tool-using models (run by the registry's goose), or an Anthropic or OpenAI key (Claude Agent
or Codex). The app installs the agent, puts the key in its environment in the computer, and
makes it the default. A chat whose agent is signed out offers **Sign In** and **Switch
Agent**. Agent Settings also installs and updates any
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

### Tools

**Tools** (in the Agents tab's toolbar, or the side bar's actions) is the computer's MCP
Library: MCP servers from [Smithery](https://smithery.ai) that give agents more to work with.
A server added here is available to every agent on this computer, in new chats; servers
belong to the computer, like apps, so there is no choosing per agent or per teammate.

The first time, the sheet asks to **Connect Smithery**: it links to Smithery's API keys page
(`https://smithery.ai/account/api-keys`) and takes a key in a secure field. Each computer
connects once. The key goes to the host, which keeps it and never passes it to the computer
or back to a client; Smithery hosts each server and holds its sign-ins and settings.

After that, the sheet lists **On This Computer**, the servers added, with how each is
doing (asked of Smithery afresh each time the sheet opens, and on pull to refresh):
connected with its tool count; **Sign In**, which opens Smithery's page for the server in
Safari inside the app and checks the server again when it closes; **Set Up**, a form of the
settings the server asked for (header values are entered as secrets), sent only once every
required one has a value, with Smithery's own page for them when it offers one; or a failure with its reason and
**Check**. Each row's menu has Check Again and Remove. A computer holds up to 20 servers;
at the limit, Add is unavailable and the sheet says to remove one. Below come rows of
Smithery's servers, drawn like the app Library's: Popular, ranked by uses on Smithery,
Verified, whose publishers Smithery has verified, then topics, each with See All. Search
lists Smithery's matches after a 300 ms pause, 40 at a time as you scroll. Adding a server
that needs a sign-in or settings opens that step at once.

A server's details show its icon, name, qualified name, Smithery's verified seal, its uses,
what it does and the tools Smithery lists, with Add, or its status, Check Again and Remove.
Neither popularity nor the seal is a review, and the details say so: "Smithery lists this
server; Caboose hasn't reviewed it." Removing a server removes it from Smithery at once;
chats lose it on their next call to it. The account sits at the end of the page, with
**Disconnect**, which removes the computer's servers from Smithery and forgets the key.
Icons come through the host (`/v1/mcp/icons`), decoded to at most 128 pixels and kept in
memory; a server without one shows its initial. The routes answer from the host, so Tools
works while the computer is parked and never wakes it, and the sheet follows
`mcp.changed` events on the control socket.

On a device paired to a computer, check Tools: connect a Smithery key; add a server that
needs no settings and see it connect with a tool count; add one that needs a sign-in, sign
in on Smithery's page, close it and see the server connect; add one that asks for an API
key, fill in the form and see it connect; start a new chat and ask the agent to use one of
its tools; remove a server; disconnect and see the servers go.

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

Swipe a live preview upward to close it. The preview lifts with the finger, shows its
progress, and gives a light haptic at “Release to close.” Release after 64 points of
predominantly upward travel to send one normal close request. Short, downward or sideways
swipes cancel; horizontal scrolling, tap to open, context-menu Close and VoiceOver's Close
action remain available. Unsaved-change dialogs belong to the application, and its tile
stays until the window closes. Reduce Motion keeps the directional cue without moving or
scaling the preview.


Ask opens windows, apps and the home's files by name (every word must start a word of the
name, ignoring case and accents; windows first, then apps, then files) and, with an agent
available, hands what was typed to the default agent as a new chat. Return takes the first
row.

On an iPhone whose bars are horizontal, the tabs sit at the bottom right instead of the
system's bar across the bottom: a glass cluster beside Ask when the phone is upright, and a
sidebar down the trailing edge with the tabs at its foot once the screen is 600 points wide
(an iPhone Duo opened out, or any phone on its side). The cluster goes under the software
keyboard, as the system's tab bar does; the sidebar stays, its tabs riding above the
keyboard, as the system's vertical bar does. Desktop keeps its navigation and dock even
when a Linux app requests fullscreen; that app fills the workspace above the dock. Where the system
draws its vertical bar (iPhone Duo, iOS 27.1), and on iPad, the system's tab bar is used,
except wide portrait Desktop, whose controls and navigation share the compact dock-side panel.
With the native vertical bar, Ask, the Agent composer and the tiled Desktop dock end on
the same bottom baseline. Check all three tabs on the closed Duo and after rotation;
show the keyboard in Agents and confirm the composer still clears it.
The last installed-app response (including icons, at most 16 MiB) is cached per pairing.
Relaunch the phone app after its first successful app scan: Home and the dock retain their
icons while the host refreshes. Switching computers never displays another pairing's apps;
signing out removes its cache. Removed apps disappear on the next successful refresh.

## Computer settings

The cog in every tab's toolbar opens **Computer**: the computer's name, the memory and cores
it boots with (applied on the next restart), how long it waits before parking, Park Now,
Restart, the wallpaper, and Change Computer. Its Display row opens the connection's
diagnostics: the reconnect state and recent losses, the network path and address, and
what the phone measured on the current connection (round trip, data received, decode and
queue times, send backlog, typing echo). A figure without a sample shows a dash. Beside the cog, the lifecycle menu shows the
computer's state and offers Turn On, Park and Restart as they apply. Both use the host's
management API (`docs/architecture.md`) and follow `computer.settings` events on the control
socket. The Apps tab lists every app on the computer, with System Settings & Tools last; its
Library button (top right) opens **Library**, every app the computer can add. Its front page is rows of icons: Popular,
then one per category, Caboose's curated apps among them, each with Get, its progress, Retry or
Open. See All lists a row's whole category, and Search (after a 300 ms pause) lists matches
across everything; those lists show each app's developer (with a seal for Flathub's verified
publishers) and license, and load more as you scroll. Each app installs on its own. Apps update
on their own; an app with a newer version waiting is listed under Updates with Update Now. An
app this computer cannot install says why (a container computer made before Flatpak support
must be recreated). The Library comes from the host's own index, so it works while the computer
is parked and never wakes it; getting, updating and removing an app need the computer running,
and the host's reason shows when it is not.

**New App**, beside Library, makes an app instead of installing one: describe it, tap Create,
and a chat starts with the default agent asking for a Caboose app (`guest/apps`). The chat
opens in Agents; the agent publishes the app, and it appears in Apps with its own icon.

The wallpaper lies behind every tab and the desktop, here and on a TV: the brand gradient,
wallpapers that change every quarter hour, one wallpaper, or a picture of your own from
Photos. Rotation uses the 67 curated Unsplash photographs served by Lorem Picsum, with
photographer credits in the picker (`Desktop/Wallpapers.swift`). Photos download on demand
at up to 4K. The selected library picture is retained in Application Support for offline
use across cache purges, app launches and host reconnects; a failed download keeps it visible.
Twelve generated scenes are also selectable and render on the device. Custom photos remain
in Application Support. Choose the background in Computer settings, from the Desktop's
overflow menu, or with a long press on Home's background.

Wallpaper check on a device: choose Rotating and then Next Wallpaper; both show real photos.
Choose a photograph, relaunch offline and confirm it reappears. Choose a generated scene and
relaunch offline; it remains selected. Clear only Library/Caches/Wallpapers in a development
app container, relaunch offline and confirm the selected picture remains. Rotate/fold and
reconnect to the computer; it stays visible while another size loads. Import Your Photo,
relaunch and confirm it remains.
Restore Rotating from a generated scene and confirm a photograph replaces it when online.
Check the picker credits and confirm the wallpaper stays aligned behind the shell capsules
in portrait, landscape and on an external display.

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
- **Connection recovery.** Run `apps/ios/scripts/check-reconnect.sh` and follow its checks:
  Wi-Fi and cellular hand-offs, no network, a link that stalls without closing, locking,
  an external monitor unplugged, asleep or plugged in mid-reconnect, another device, a
  cold boot, and the figures in Computer settings › Display.
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
- **Game handoff.** Install The Powder Toy from Library and open it. Its window shows the
  game running on the device, with sound, touch, a hardware keyboard and a game controller;
  nothing it draws comes from the computer. Draw something and save it in the game, close the
  window, and find the save under `~/.local/share/The Powder Toy` on the computer; open the
  game again and load it. Change that file on the computer while the game runs and save from
  the game again: the device's version arrives beside it as `<name> (iPhone).<ext>`. Leave the
  window for Home: its picture is the game's last frame. Lose the network mid-game and come
  back: the same game is still running. A debug build lets Safari's Web Inspector attach to
  the game's page: `crossOriginIsolated` is `true` there, and its address is
  `http://127.0.0.1:<port>/<token>/`. Background the app for several minutes mid-game and
  return: the game still loads files. On a device whose WebKit cannot isolate the page, or
  with a game that crashes its page twice in a minute, the window says "Running this game on
  the computer instead…" and then shows the computer's native build.
- **Library.** Open Library from the Apps tab, install PhotoCraft, follow its progress, open
  it, and remove it.
- **Tools.** Open Tools from the Agents tab and run the check under [Tools](#tools).
- **Tabs and the vertical bar.** On iPhone Duo, closed and open in landscape, every tab's
  bar is on the side with the tabs, the cog and the lifecycle menu; on the Desktop tab the
  desktop fills the space beside the bar and resizes when the device folds or rotates; on a
  phone without the bar the toolbar is horizontal and the tabs are a cluster at the bottom
  right beside Home's Ask, or a sidebar on the trailing edge on a Duo opened out or a phone
  on its side; the cluster hides under the keyboard, the sidebar's tabs stay above it, both
  stay available around a fullscreen Switchyard window, and Agents shows its approval count. Open the Desktop's
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
  On disposable test windows, scroll the strip left and right from a tile, tap to open,
  and long-press for Open/Close. Swipe down, diagonally sideways, and up less than 64 points:
  each cancels without closing or opening. Swipe up beyond the cue, retreat, then release:
  it cancels. Release above the threshold: exactly one close request, no navigation, and
  the tile remains until the server removes it. Repeat with a disposable unsaved document:
  the app asks to save; use Cancel and verify the tile can be opened and swiped again.
  Disconnect/reconnect, switch computers, or remove the window during a drag: release
  must not affect the replacement window. Check VoiceOver's Close action, Reduce Motion,
  and cancellation by an interrupted touch. Run these checks only on a designated test
  session; never discard an owner's unsaved document. Pure threshold and one-shot tests:
  `cd apps/ios/CabooseKit && swift test --filter UpwardDismissalTests`.
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
system overflow remains; Stop and Copy Answer join its regular actions. Agent Settings
contains Connect a Model; it is not repeated in the composer or chat toolbar.
Open the power control and confirm its popover appears beside that control on both Duo
screens. Dismiss it without parking or restarting when checking placement only.

## Laptop mode

Desktop and full-screen app cards offer Screen Layout → Automatic, Tablet or Laptop.
Automatic uses a partially folded horizontal hinge on iOS 27.1 and later. Laptop also
works as a manual split on a sufficiently tall flat screen. The upper area shows the
app/desktop without the system toolbar. The lower-right control rail offers Keyboard,
Trackpad, Keyboard & Trackpad or Gamepad from one input button, whose icon is the same in every mode,
then window switching, settings, power and navigation. Opening a window from the Laptop
desktop focuses it in that workspace, and every app window fills the upper screen (one whose
minimum size is larger keeps its own); there is no separate Full Screen route or Exit App Full
Screen action. Keyboard fills the lower panel with Laptop's own keyboard under the shared
shortcut header; Keyboard & Trackpad puts a full-width trackpad across the upper third and
the same keyboard and header in the lower two-thirds. Neither opens the system keyboard: a
text field the trackpad focuses opens Keyboard & Trackpad. The keyboard's globe button opens
the system keyboard for languages, emoji and dictation, without the shortcut header (which
would land above the hinge) and with a button above it that returns to Laptop's keyboard.
Hide Keyboard returns to the trackpad. Gamepad fills the lower panel with the [on-screen controller](#on-screen-controller). The dock becomes a thin, full-width taskbar at the top of the lower half; controls stay below
the hinge. The upper desktop hides Caboose title bars and gives their space to the app;
app-owned chrome remains. Its pointer reaches both the app and relocated dock. Tablet
mode retains its saved arrangement. One-finger movement, tap/double-tap, two-finger
scroll/right-click, pinch zoom, three-finger drag and four-finger window switching use
the shared trackpad gestures. Four fingers up opens the window chooser; down closes it.
Pinch uses the focused app’s Control–Plus/Minus shortcuts. Both control surfaces offer a
Trackpad Gestures guide with the mappings and platform limitations. With a connected
monitor, the phone shows window previews above its keyboard/trackpad and leaves the monitor's
workspace intact. Book posture and compact screens keep the ordinary layout in Automatic.

### On-screen controller

Laptop's Gamepad mode and a TV's Gamepad draw the same controller, aimed at the window the
keyboard would type into. A strip at its top chooses the controller type, names where the pad
goes ("Controller for …" or "Keys to …"), opens Customize and, filling the phone, leaves.
There are four types, each laid out and drawn as the controller it recalls:

- **Modern**: offset twin sticks, a d-pad, A/B/X/Y, bumpers, analog triggers, View, Menu and
  Guide, marked Xbox or PlayStation (✕ ○ □ △, L1/R1, L2/R2, Create, Options).
- **Classic**: a d-pad, the four-colour B/A/Y/X diamond, L and R, slanted Select and Start.
- **Retro**: a d-pad, B and A, Select and Start.
- **Arcade**: an eight-way lever and eight buttons in two curved rows (X Y RB LB over
  A B RT LT, or their PlayStation marks), Select, Guide and Start.

Each type has a wide arrangement (a landscape phone, the panel below a hinge) and, but for
Arcade, a tall one (a portrait phone); the pad uses whichever gives larger controls. Controls
hug the sides, where thumbs are, and the bottom, and extra width opens the middle. Each app
keeps the type last chosen for it; a new app starts with the last type chosen.

A finger belongs to what it lands on until it lifts, and a thumb a little off a control still
takes it. On the face buttons and shoulders it presses whatever it slides onto, and resting
in the seam between two neighbours presses both (never two across the diamond). Sticks float
by default: a stick centres wherever its thumb lands on its side of the pad and follows a
thumb carried past its rim, so reversing answers at once; Customize can fix them in place.
A stick reads nothing in its centre tenth and full at 85% of its travel. Tap then press a stick
to click it (L3, R3) for as long as the press lasts. A trigger pulls fully when touched and
eases off, down to 15%, as its finger slides down, for throttle and brakes. The d-pad and
lever have eight directions. Presses, d-pad direction changes and stick clicks each have
their own haptic, and the pad defers the screen-edge system gestures.

A game running on this device ([game handoff](../../docs/game-handoff.md)) gets it as a
standard controller through the page's Gamepad API; every other window, and a game when
Customize says so, gets keys, each held for as long as its control is (by default the d-pad and
left stick are the arrow keys, the right stick W A S D, A Space, B Escape, Start Return). A key
belongs to a button's place on the controller, so it carries across types. The computer gets
no controller device. Customize sets the type, markings, sticks, size, haptics and every key,
and remembers them; leaving the mode, a change of window, game, connection or settings,
opening Customize or leaving the app releases everything held, and a finger still on the pad
then controls nothing until it lifts. `CabooseKit/Input/OnScreenGamepad*.swift` holds the
types, layouts and touch tracking, unit-tested for every type at every pad size.

In Tablet mode, portrait Desktop at 600 points or wider has a controls icon at the far-right end of the bottom dock. Its
upward, anchored strip shows desktop controls and app navigation as a single vertical
column of icons, with Close and VoiceOver escape to dismiss. The strip is 72 points wide
and scrolls within 512 points; it never becomes a full-height rail or reserves desktop space.
A closed phone keeps its native right-hand sidebar rather than selecting the tablet panel. Native toolbar and
tabs are hidden on this path, including iPad system tabs and Duo's native rail.
Landscape keeps the native rail where available and otherwise the custom rail. Laptop
keeps its bottom-half controls. Window bounds select portrait independently of the keyboard.
Run `sh apps/ios/scripts/check-desktop.sh` for rotation, keyboard, fullscreen and
return-from-tab checks on a device. Pure orientation policy is covered by
`swift test --filter DesktopChromeTests`; measurement-to-guest and dock geometry by
`swift test --filter DeviceViewportTests`, both in CabooseKit.

The device monitor retains its full-screen square dimensions and the DPI selected at
attachment, including an active desktop's existing UI scale. Cards, keyboard, folding and
stage layout update window viewports without changing that monitor. External modes and
explicit owner zoom remain monitor changes. Ordinary card/dialog requests honor per-axis
size hints; app fullscreen retains compositor geometry and uses the existing aspect-fit
presentation/input transform. No fixed minimum desktop resolution is imposed.

`swift test --jobs 1 --filter 'MonitorPolicyTests|WindowSizePolicyTests|FullscreenGeometryTests|CardWindowFitTests|DeviceViewportTests|DesktopGeometryTests|CabooseDisplaySessionTests'`
checks monitor retention/external precedence, initial DPI/render-scale preservation,
minimum/maximum hints at the shared configure boundary, fullscreen restoration and fitted
position/delta geometry. Desktop trackpad scrolling snapshots the shown rectangle and
committed remote size and cancels when either changes, including during inertia. These pure
checks do not validate Wine's live DPI transitions or actual-device fullscreen input.

Run `sh apps/ios/scripts/check-laptop.sh` for the physical Duo, keyboard and monitor checks.
Pure fold/keyboard geometry is covered by `swift test --filter LaptopLayoutTests` in CabooseKit.

## Media playback checks

The app renders moving video inside the window stream by default. It does not negotiate
separate motion or passthrough layers. Test an ordinary video page through resize,
fullscreen/exit, minimize/restore and Laptop/Tablet transitions: one picture must move
with its window. Audio packets play on a continuous sample timeline; test sustained
speech/music, pause/resume and an audio-session interruption without choppy gaps.

Laptop reopen check: with one app open, relaunch while the phone is bent. The app fills
the upper panel through its bottom edge; delayed window metadata or a settling safe area
must not leave the initial cascade frame surrounded by wallpaper.
## Paired computer menu

Tap the name and chevron on Home to select a saved computer or Add Computer. Adding a
pairing keeps the others. Manage Computers opens the host console, where an authorized
administrator signs in to provision computers and generate pairing codes. The phone lists
only computers explicitly paired here. Keychain failures appear as sign-in errors and do
not disconnect the current computer.

Run `python3 apps/ios/scripts/test-computer-switcher.py` from the repository root for pure
collection tests. On a signed phone, pair two computers at one host and another on a
second host; switch while waking, reconnecting, searching files, and loading apps. Verify
names and the selected checkmark, no old frames/apps/tasks after switching, separate Files
identities, and retained pairings after relaunch. Cancel Add Computer and verify the old
pairing remains. Re-pair a computer and verify its Files identity persists. Rename it in
settings and verify the menu retains the name after relaunch. Open Manage Computers and
verify ordinary console sign-in with no phone bearer in the URL. With Keychain access
unavailable, verify the failure is shown and the active connection is unchanged. Start from
a legacy single pairing and verify migration keeps its Files identity and shortcuts.

Tablet-portrait shell check: on Home, Agents, Apps and Terminal, navigation forms a
compact bottom-right, icon-only navigation capsule with a separate controls capsule
above it, matching the native side toolbar. Page actions and power are in its overflow.
There is no empty full-height glass, black background strip, or duplicate top toolbar. Page content, Ask, composers
and the terminal fit beside it. Rotate to landscape and back, then show and hide the
keyboard; the rail stays reachable above it and no second tab bar appears.

Terminal fold and keyboard checks:
- Open Terminal on the closed Duo and inner display in both orientations: the software
  keyboard starts hidden, the prompt remains visible, and Home/Desktop/Agents/Apps tabs
  remain reachable. Tap the prompt to type; Hide stays at the header’s top right.
- Rotate landscape → portrait → landscape with the keyboard open and closed: the same
  shell output remains visible, with no blank wallpaper replacing the grid.
- Bend into Laptop: output occupies the upper screen; the lower screen has Sessions,
  navigation, shared shortcut keys and compact typing keys, with no mouse or trackpad.
  Check Ctrl+C, Tab completion, arrows, Return and Backspace; the globe opens the native
  keyboard for dictation/languages. Hide and Show Keyboard work; flattening restores tabs.
- Open Sessions from both the sidebar and Laptop deck: the popup points to that button.
- Leave a full-screen desktop app for Terminal, then select Desktop again: its dock
  and navigation return. Full Screen remains an explicit action inside the desktop.

- **Desktop fullscreen chrome regression.** With an app fullscreen inside Desktop, fold
  to the front phone, unfold, and rotate both ways. The app ends above the dock; navigation
  remains visible (or in the dock's compact portrait control). There is no empty reserved
  sidebar. Switch to Terminal and back, then background and reopen: controls remain.
  Separate app cards retain their own hide/reveal controls, and Laptop keeps its lower deck.

### Desktop files and launch feedback check

On a paired device, create a folder and import a file using Desktop's menu or drop a file URL onto Desktop. Open, rename,
move to Documents, and Trash the item; verify the corresponding real home paths in Linux
Files. A name collision refuses replacement. Rotate and connect an external display: both
show the same Desktop items; trackpad primary click opens and secondary click offers actions.
Close every window: wallpaper and Desktop remain; All Apps opens only from its button.
Window Overview uses overlapping rectangles and shows an empty-window state when empty.

Hold a dock app and Add Shortcut to Desktop; verify the standard `.desktop` file in Linux.
Open it on iOS and verify the installed app launches. Remove its installed target or replace
its marker with an unknown ID: iOS reports it unavailable without executing its Exec field.
Tap a closed app repeatedly: feedback starts immediately and only one launch is sent; a real
matching window stops it. Launch two apps: feedback is independent. Simulate a host launch
error and a launch with no window: feedback stops with the corresponding error or delayed
opening message. The window deadline starts after HTTP acknowledgement; request errors
must remain visible instead of being replaced by that deadline. Verify a window that arrives
before the acknowledgement stops feedback and is not resurrected by the late response.
Use a desktop entry whose `StartupWMClass` differs from its ID to check declared-class
matching. Repeat with Reduce Motion, reconnect, and a running minimized app.
Pure identity and acknowledgement fencing checks: `swift test --filter
'AppWindowIdentityTests|DesktopItemPolicyTests'` in CabooseKit.

Desktop imports copy one file at a time; they do not establish Open in Place synchronization.
Items use file-type icons and name ordering; manual placement and file previews are absent.

Computer settings offer the sizes provided by the host and custom CPU and memory.
GPU access uses the host GPU and is shared; availability reflects host configuration.

Desktop checks: launch a handed-off game directly in Laptop mode, then flatten and fold
the device; the live game stays visible and fits its window. In tablet portrait, the
window’s green Full Screen control hides the dock and chrome; the return handle restores
controls. Reveal the sidebar, swipe it outward over its buttons or empty space, and reveal
it again: after five idle seconds it hides. An open menu, keyboard, or VoiceOver keeps the
controls available. Rotate or fold a handed-off game with the sidebar visible and hidden:
the game fills the viewport without a wallpaper strip or a restart.
Swipe horizontally across All Apps to change pages; vertical drags and short
taps do not page. Opening Caboose does not read the system pasteboard.

Agent selection check: open a chat whose last message is “hey”, open the composer agent
menu and select another agent. The empty/new composer names the selected agent; no chat or
message is created until Send. The previous chat and its unsent draft remain in Chats. Repeat
from a signed-out chat’s Switch Agent action. Open Agent Settings and connect/sign-in
controls there; the composer and toolbar contain no separate Connect a Model action.

### Direct-touch scroll check (device)

Use a connected computer with a scrollable Xwayland application and a native Wayland
application; repeat in a window card and on the free desktop. This checks the shared
input path without application-name rules.

1. In mouse-only content, swipe vertically and horizontally away from the scrollbar.
   Content scrolls, coasts after lift, and stops on a new touch. No mouse selection or
   click occurs at lift. Tap a button and a text field: each still activates once.
2. Hold a text selection or draggable control for half a second, then move. It drags
   instead of scrolling; lifting releases it once. Small stationary finger jitter must
   not prevent the hold. A two-finger tap still opens the context menu.
3. Add a second finger during a held drag, background the app, change its target, or
   close the window. No pressed button or late click survives; a fresh touch works.
4. On the desktop, drag a title bar and resize handle immediately; content gestures do
   not move the window. Repeat with a mouse and Pencil: their direct strokes still drag.
5. In native-touch content, swipe and pinch: the Linux app still owns those gestures.
   Check a native context hold and ordinary keyboard focus as well. Laptop trackpad
   gestures remain one finger to point and two fingers to scroll.
