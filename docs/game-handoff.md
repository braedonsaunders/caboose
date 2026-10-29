# Game handoff

Game handoff runs a game on the phone or iPad instead of on the computer. The game is
installed, stored and launched on the computer like any application, and its window is an
ordinary Wayland toplevel on caboose-display, so the window list, focus, geometry, icons
and Home behave as they do for every other window. The game itself is a WebAssembly build
(WebGL2, WebGPU, WebAudio, the Gamepad API). caboose-display tells the client which window
the game belongs to and where its files are; the client runs the game in a `WKWebView` laid
into that window and streams the game's files from the computer. Rendering, sound and input
stay on the device, and the computer does no per-frame work for the window.

It is the compute counterpart of [codec passthrough](codec-passthrough.md). The pieces:

| Piece | Where |
| --- | --- |
| `caboose-game-run`, the launcher, and the bundles Caboose ships | [guest/game](../guest/game/README.md) |
| The game socket and the binding to a window | caboose-display, `compositor/src/game.rs` |
| `game.create` and `game.destroy` | [display.md, "Game handoff"](display.md#game-handoff) |
| The game surface, its loopback origin, save sync | CabooseKit, `Sources/CabooseKit/Game` |
| Catalog games | [guest/catalog](../guest/catalog/README.md) |

## Bundles

A game is a directory, its **bundle**, under `/home/caboose`, holding a manifest named
`caboose-game.json` and the game's web build:

```json
{
  "version": 1,
  "title": "The Powder Toy",
  "app_id": "uk.co.powdertoy.tpt",
  "root": "web",
  "entry": "index.html",
  "saves": [{ "mount": "/powder", "path": ".local/share/The Powder Toy" }],
  "native_fallback": ["native/powder", "ddir", "~/.local/share/The Powder Toy"],
  "window": { "size": [1280, 800], "min": [640, 400] }
}
```

| Key | |
| --- | --- |
| `version` | `1`. |
| `title`, `app_id` | The window's title and Wayland app id. `app_id` names the desktop entry and icon, like any application's. |
| `root` | The directory the game's files are served from, relative to the bundle; default `.`. |
| `entry` | The page the client loads, relative to `root`. |
| `saves` | Optional. Each `mount` is a directory of the game's Emscripten file system that it persists with IDBFS; `path` is the directory on the computer that holds it, relative to `/home/caboose`. |
| `native_fallback` | Optional. A command that plays the game on the computer: the first element is relative to the bundle when it contains `/`, else found on `PATH`; a leading `~/` in any element is the home directory. |
| `window` | Optional. `size` is the window's first size; `min` and `max` bound it. Logical pixels. |

`root`, `entry`, every save `path` and `native_fallback`'s program must stay inside the home
(no `..`, no absolute paths, no symlinks on the way); `caboose-game-run` refuses a manifest
that breaks this.

## Launching

`caboose-game-run <bundle or manifest>` opens the game's window on `WAYLAND_DISPLAY`: a
GTK window with the game's icon, title and one line of status, committed once, which is the
window's whole picture. Once the window is mapped it connects to `$CABOOSE_GAME_SOCKET`, says
`hello`, and waits for `mode`:

- `handoff`: a client runs the game. The window says so and the launcher does nothing else
  until its window closes.
- `local`: no connected client runs games. As its first answer, `local` makes the launcher
  run `native_fallback`, if the bundle has one, in place of itself (its window closes and the
  native game opens its own); otherwise the window asks for Caboose on an iPhone or iPad.
  After a `handoff`, a `local` (the device went away) only changes the status line, and a
  later `handoff` resumes.
- `local` with `declined: true`: the device could not run the game it was given (see
  "Declining"). The launcher runs `native_fallback` in place of itself whenever it comes, or,
  without one, says the device could not run the game and the computer has no build of it.

Without `CABOOSE_GAME_SOCKET`, or when the socket does not answer within five seconds, the
launcher behaves as for a first `local`. The agent seat has no game socket, so a game an agent
opens there always runs natively or not at all.

The window closes when the client closes it (`close`) or the launcher's window is closed on
the computer; the launcher then exits, which ends the game.

## The game socket

caboose-display listens on `$XDG_RUNTIME_DIR/caboose-game.sock` (mode 0600) for the owner's
display and writes `CABOOSE_GAME_SOCKET` into its launch environment. Each message is framed
like the display protocol: `type: u8`, `length: u32` little-endian, then one canonical CBOR
map with text keys. Unknown types are skipped by length, unknown keys are ignored, and a
payload larger than 64 KiB closes the connection.

| Direction | Type | Message | Fields |
| --- | --- | --- | --- |
| launcher → display | `0x01` | `hello` | `version: 1`, `title`, `app_id`, `root`, `entry`, `saves?: [{ mount, path }]` |
| display → launcher | `0x81` | `mode` | `mode: "handoff"\|"local"`, `window?: uint`, `declined?: true` |

`root` is the served directory relative to `/home/caboose` (the bundle's path joined with its
manifest's `root`), `entry` is relative to `root`, and `saves` are as in the manifest.

SO_PEERCRED gives caboose-display the launcher's pid, and the game is bound to the first
toplevel whose Wayland client has that pid. A launcher whose window does not exist within
five seconds of its `hello` gets `local` and is not bound. One window carries at most one
game; a second connection from the same process replaces the first.

caboose-display answers `hello` with the current mode as soon as it is known, and sends it
again whenever it changes: `handoff` (with `window`) while the connected client listed
`wasm: true` in its hello, and `local` while no client is connected or the client did not.

## On the display connection

While a game is bound and the connected client plays games, caboose-display sends
`game.create { id, window, root, entry, saves? }` after the window's `window.create`
(including in the burst that answers each `hello`), and `game.destroy { id }` when the
launcher disconnects or its window closes. Game ids are their own namespace, unique for the
server process's lifetime. While its game is shown on a client, the window sends no
`frame`, `tile` or video stream, and `request_keyframe` for it is ignored. The client's
`configure` and `close` for the window are handled as for any window.

### Declining

A client that finds it cannot run a game it was given (its page needs threads WebKit will not
give it, or its web content keeps crashing) sends `game.decline { id, reason }` once per connection, after
writing the saves still on their way. caboose-display takes it only for a game it announced
to that client and not yet withdrawn, once: it sends `game.destroy`, the window sends its
pictures again, and the launcher hears `local` with `declined`, so the bundle's native build
replaces it and the client sees the game as an ordinary window. The game stays with the
computer for the rest of the launcher's life. The client says it is handing the game back,
and says so plainly if no `game.destroy` follows within ten seconds (a computer that does not
know `game.decline` skips it).

## The client

CabooseKit lays a `WKWebView` over the window's content in `RemoteWindowView`, sharing the
window's chrome, title bar, resizing and Stage Manager placement. The web view uses a
non-persistent website data store, so the computer is the only place a game's state lives.
It loads `http://127.0.0.1:<port>/<token>/<entry>` from the game's own server on the device,
and navigates nowhere else: a link or a window to any other address opens nothing.

**Files.** Each game has a `GameServer`: an HTTP/1.1 server listening on `127.0.0.1` (the
loopback interface only, on a port the system picks) from before its page loads until the
game ends, the page is declined or the session ends, when the listener and every connection
close. The page is served over loopback HTTP rather than a custom URL scheme because WebKit
makes only http(s) origins cross-origin isolated, which threaded WebAssembly
(`SharedArrayBuffer`) needs, and `127.0.0.1` is a potentially trustworthy origin, so the page
is a secure context. Its own port gives each game its own origin.

The server answers only requests whose `Host` is exactly `127.0.0.1:<port>` and whose first
path component is the game's token, 128 random bits in hex, compared in constant time;
anything else is 404 (a wrong `Host` is 400). Only `GET` and `HEAD` are served (405
otherwise), read-only and without directory listings. A request head is at most 16 KiB
(431), must arrive within 10 seconds, and has no body; at most 32 connections are open at
once, each carries one request (`Connection: close`), and a response that makes no progress
for 60 seconds is cut off. The rest of the path is resolved against `root` (a `..` that
leaves `root` is refused with 403) and served through the host's `/v1/fs/stat` and
`/v1/fs/content`, with the host's bearer token, which never appears in a URL or a response.
Each file is kept in `Caches/CabooseGames`, keyed by the computer, its path and its `etag`,
so a file that has not changed loads from the device on the next launch; a file not cached
streams to the page as it arrives. A request with a single `Range` is answered 206 (or 416)
from a cached file, and passed to the host when the file is not cached; any other `Range` is
answered with the whole file. Every response, the page's, its workers' and every other,
carries `Cross-Origin-Opener-Policy: same-origin`, `Cross-Origin-Embedder-Policy:
require-corp`, `Cross-Origin-Resource-Policy: same-origin`, `Cache-Control: no-store` (the
cache is the app's) and a `Content-Type` from the file's extension (`application/wasm` for
`.wasm`, so it compiles while it streams). The system can close the listener while the app is
suspended; the server then listens on the same port again, so the page keeps its origin.

**Saves.** Before the page loads, the client lists every save `path` on the computer
recursively and downloads its files. A user script at document start (`window.cabooseFS`)
answers IndexedDB for the databases IDBFS opens for the save mounts (IDBFS names a database
after its mount point) from those files, and leaves every other database to WebKit. When
IDBFS writes, the script sends the changes to the app, which writes them to the computer
with `PUT /v1/fs/content`: `If-Match` with the etag it last saw, `If-None-Match: *` for a new
file, `POST /v1/fs/mkdir` for directories and `DELETE /v1/fs/item` (to the Trash) for
removals. When the computer's copy changed underneath (412), the device's version is written
next to it as `<name> (iPhone).<ext>` (or `(iPad)`), so neither is lost. Writes go out within
two seconds; before the client sends `close` for a game window it waits, for up to five
seconds, for the writes in flight. The delayed close applies only to the same connection,
window and game; replacing any of them cancels that close.

**Input.** Touch, the hardware keyboard, the pointer and game controllers (the Gamepad API,
from GameController) go to the web view on the device; none of it is sent to the computer.
An on-screen controller the app draws (Laptop's Gamepad mode) appears to the page as one more
gamepad. The app's
own controls aimed at the window (Laptop's trackpad and keyboard, the key bar) reach the
page as DOM events through `window.cabooseInput`, a script the client adds at document
start:

- The pointer is `pointer*` then `mouse*` events at the element under it (the element a
  button went down on, while one is held), with `over`/`enter`/`out`/`leave` as it crosses
  elements, `click`, `dblclick` and `contextmenu`, and `wheel` in CSS pixels. Positions are
  sent as fractions of the window and scaled by the page's viewport.
- Keys are `keydown`, `keypress` for a key that types, and `keyup` at the focused element,
  with `key`, `code` (a US layout), `keyCode`, `which`, `charCode` and `repeat` (a key
  pressed again while down). A key typed with modifiers presses and releases them around
  it, and so does a pointer press (until its last button lifts) or a wheel turn with
  modifiers; text is typed key by key.
- What is held is released (keys up, buttons cancelled with `pointercancel` then `mouseup`)
  when a press, key or text goes to another window, focus moves, the connection goes, the
  game ends, its view leaves the screen, or the app stops being active.

These events are untrusted (`isTrusted` is false), so a page that ignores untrusted input
takes only touch, hardware keys and controllers. Resizing, fullscreen, focus and closing the
window still go to caboose-display as `configure` and `close`.

**Pictures.** The window's picture, which Home and the window strip show, is a snapshot of the
web view, taken when the game's view leaves the screen.

**Declining.** The client declines a game (see "Declining" above) when its page stops on an
uncaught error while it is not cross-origin isolated, when WebKit ends the page's content
process a second time within a minute (the first time, the page loads again from the saves
written so far), or when the device cannot start the game's server. The page stops at once,
the game's window says "Running this game on the computer instead…", the saves still on
their way are written (for up to five seconds), and then `game.decline` goes with the reason,
at most 200 UTF-8 bytes. It goes only while the game is still its window's game on the
current connection, after that connection announces it, once per connection. A game declined
while disconnected, or whose decline was unanswered when the connection dropped, is declined
when the same server announces it again. Reconnecting never skips the pending save wait. When no `game.destroy` follows within ten seconds,
the window says "This game cannot run on this device, and the computer did not take it back.
Close the window."

## Catalog games

A catalog app whose `source.kind` is `game` is a pinned web build plus a bundle Caboose
ships (see [guest/catalog](../guest/catalog/README.md)). Installing it downloads and checks
the archive, unpacks it as the owner into `~/.local/share/caboose/games/<id>`, adds the
shipped manifest and page, the native build for the computer's architecture when the source
has one, and a desktop entry that runs `caboose-game-run`. Removing it removes the bundle and
the desktop entry and keeps the saves.

## Limits

- **Emscripten saves only.** Saves are synchronised for games that persist through IDBFS.
  A game that keeps state in `localStorage`, OPFS or its own IndexedDB databases loses it
  when its window closes.
- **One device.** A game runs on one client at a time, like the display. When another device
  takes the display, the game restarts there from its last synchronised saves.
- **WebKit decides what runs.** WebGPU, threads, pointer lock and the Gamepad API are what the
  device's WebKit offers. A game that needs more fails in the web view and shows its error,
  unless its failure is one the client declines the game for.
