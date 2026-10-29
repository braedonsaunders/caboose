# Games in the guest

The computer's half of [game handoff](../../docs/game-handoff.md): `caboose-game-run`, which
opens a game's window and either hands the game to the device or plays it on the computer,
and the game bundles Caboose ships for the catalog's games.

| File | Installed as | What |
| --- | --- | --- |
| `caboose-game-run` | `/usr/local/bin/caboose-game-run` | The launcher (Python 3 and GTK 3). |
| `games/<bundle>/` | `/usr/local/share/caboose/games/<bundle>/` | A bundle's manifest, page and icon, which a catalog install adds to the game's web build. |
| `install.sh` | | Installs both, replacing the shipped bundles as a whole. |
| `test_game_run.py` | | Unit tests. |
| `check.sh` | | The end-to-end check against a real caboose-display. |

## caboose-game-run

```sh
caboose-game-run ~/.local/share/caboose/games/powder-toy
caboose-game-run path/to/caboose-game.json
```

It reads and checks the bundle's `caboose-game.json` (the format is in
[game-handoff.md, "Bundles"](../../docs/game-handoff.md#bundles)), creates the save
directories, and opens a GTK window on `WAYLAND_DISPLAY` whose Wayland app id is the
manifest's `app_id`, showing the game's icon, its title and one line of status. Once the
window is mapped it says `hello` on `$CABOOSE_GAME_SOCKET` and follows the display's `mode`
answers as [game-handoff.md, "Launching"](../../docs/game-handoff.md#launching) specifies:

| Answer | What the launcher does |
| --- | --- |
| `handoff` | Shows **Playing on your device**. |
| First `local`, no `CABOOSE_GAME_SOCKET`, a socket that cannot be reached or closes first, or no answer within 5 s | Runs `native_fallback` in place of itself (`execv`, same process id), if the bundle has one and its program exists and is executable; otherwise shows **Open Caboose on your iPhone or iPad to play**. Without a game socket the native game starts without opening the window first. |
| `local` after a first answer, or the socket closing after one | Shows **Open Caboose on your iPhone or iPad to play**. A later `handoff` shows **Playing on your device** again. |

It exits when its window closes (the client's `close`, or closing it on the computer), on
SIGINT or SIGTERM. A manifest it refuses exits with status 2 and the reason on standard error;
so does a bundle outside the home. Every path in the manifest must stay inside the home with no
symbolic link on the way, and the served `root` must be a directory below the home, as the
display requires.

The icon is the icon theme's icon named after `app_id` (a catalog install puts the bundle's
icon there). When the theme has none, an `icon.png` beside the manifest is used.

The game socket is framed like the display protocol (`type: u8`, `length: u32` little-endian,
a canonical CBOR map); the launcher has its own canonical CBOR encoder and decoder for it, and
closes the link on a payload over 64 KiB or one that does not decode.

Configuration is the launch environment caboose-display writes: `WAYLAND_DISPLAY`,
`XDG_RUNTIME_DIR`, `GDK_BACKEND` and `CABOOSE_GAME_SOCKET`. The agent seat has no game socket,
so a game opened there plays natively or asks for a device.

## The Powder Toy

`games/powder-toy` is the bundle for the catalog's `powder-toy`, [The Powder
Toy](https://powdertoy.co.uk/) v100.1.400 (GPL-3.0). The catalog pins the release's
`powder-v100.1.400-wasm32-emscripten-emscripten.tar`, whose `powder.js`, `powder.wasm`,
`powder.wasm.map` and `serve-wasm.py` lie at the top of the archive and are unpacked into the
bundle's `web/`, and the `x86_64-linux-gnu` and `aarch64-linux-gnu` native builds, one of
which is installed as `native/powder`.

- `web/index.html` loads `powder.js` and calls `create_powder({ canvas, print, printErr })`
  with a full-window canvas (`touch-action: none`, no zoom or callout on iOS), keeping the
  game's aspect ratio at the largest size that fits. The canvas shows when the game calls
  `window.mark_presentable()`. A load failure, an error, a lost WebGL context or a web view
  without `SharedArrayBuffer` (this build uses threads) is shown as text.
- The web build mounts its data directory, `/powder`, as IDBFS and keeps its preferences,
  saves and stamps there (`powder.pref`, `Saves/`, `stamps/`). The native build keeps the
  same files in its data directory, `~/.local/share/The Powder Toy` (SDL's preference path
  for "The Powder Toy"), which `native_fallback` also passes explicitly as `ddir`. The save
  mount maps one onto the other, so both builds share one set of saves.
- `icon.png` is the project's 128-pixel icon; `icon-license.txt` gives its source and licence.

## Install

`install.sh`, as root, installs `caboose-game-run` and replaces
`/usr/local/share/caboose/games` with the bundles in `games/`. It is part of the guest
components bundle ([guest/components](../components/README.md)), which also provides
`python3-gi` and `gir1.2-gtk-3.0`: both guest images run it, and the host runs it in existing
computers when the bundle changes. Games themselves are installed from the catalog
([guest/catalog](../catalog/README.md)).

## Test

```sh
python3 guest/game/test_game_run.py
```

The unit tests cover the manifest (required keys, window sizes, saves, unknown keys), path
safety (`..`, absolute paths, symbolic links on the way, the home itself), the creation of
save directories, `native_fallback` resolution (bundle, home and `PATH` programs, `~/`
arguments, a missing or non-executable program), what each answer does, canonical CBOR
(shortest integers, key order, round trips, malformed input), framing (split reads, skipped
types, the 64 KiB limit), the socket against a real Unix listener, running natively without a
socket, and that every shipped bundle is valid. They need Python 3 only, no GTK or display.

`check.sh` runs caboose-game-run against a real caboose-display, driven by
`caboose-display-probe`. It starts a private display instance as `caboose` (its own runtime
directory, port and Wayland socket), so it does not disturb the owner's display, and checks
that:

1. a client that plays games (`--wasm`) gets `game.create` for the launcher's window with the
   bundle's root, entry and saves, that window sends no picture, the native fallback does not
   run, and closing the window from the client ends the launcher and destroys the game;
2. with a client that does not play games, the native fallback replaces the launcher;
3. without `CABOOSE_GAME_SOCKET`, the native fallback replaces the launcher at once.

In the caboose-display dev container, with Docker and network access (it installs the GTK
bindings in the container):

```sh
docker build -t caboose-display-dev guest/display
guest/display/scripts/dev.sh cargo build
guest/game/check.sh
```

On a computer, as root, after the guest components are installed:

```sh
sudo bash guest/game/check.sh --here                                          # microVM
docker exec -i -u root caboose-owner bash -s -- --here < guest/game/check.sh  # container
```

`CABOOSE_CHECK_PORT` picks the private display's port (default 14690). Installing The
Powder Toy from the catalog and opening it is checked on a deployed host with
`CABOOSE_CATALOG_APP=powder-toy node apps/host/scripts/check-catalog.mjs`
([apps/host](../../apps/host/README.md)). Playing it on a device is a device check
([apps/ios](../../apps/ios/README.md)).
