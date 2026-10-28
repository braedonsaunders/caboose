# Caboose for iOS

The iPhone and iPad app, and **CabooseKit**, its native Xpra client.

## Layout

- `CabooseKit/` — Swift package, no app UI. `Protocol/` (rencodeplus codec, Xpra packet
  framing, WebSocket transport), `Session/` (capabilities and HMAC challenge, the window
  registry, per-window draw pipelines with flow-control acks, clipboard, notifications,
  keyboard mapping), `Video/` (VideoToolbox H.264 → IOSurface BGRA, Metal window surfaces),
  `UI/RemoteWindowView` (presentation and touch/trackpad/keyboard input).
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
