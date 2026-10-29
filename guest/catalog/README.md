# Application catalog

Caboose's curated applications, the first entries of every computer's Library. The Library
follows them with Flathub's desktop applications (`docs/architecture.md` § Catalog).
caboose-host serves both at `GET /v1/catalog` and `GET /v1/catalog/discover`, and installs,
updates and removes them inside the computer (see [`apps/host`](../../apps/host/README.md#catalog-and-craft-jobs)).

| File | What |
| --- | --- |
| `catalog.json` | The curated apps. |
| `schema.json` | A JSON Schema describing `catalog.json`. |
| `icons/` | Each app's 128-pixel icon (`<id>.png`) and its licence files. |
| `extract-icons.sh` | Regenerates the Debian apps' icons from their packages. |

Each app has an `id`, `name`, `summary`, `category` (one of the Library's categories), an
`icon` name (the `Icon` key of its desktop entry), its `desktopId`, and `fileTypes`
(`extensions` and iOS `utTypes`) for opening documents in place. Craft apps also name their
`cli` and `mcp` commands, which Craft jobs and agent tasks use. A Debian app names the Flathub
application it also is in `flathub`, so the Library shows it once; so does a game. An app's
`source` is one of:

- `{ "kind": "apt", "packages": [...] }`: Debian packages from the signed Debian 13
  repositories; or
- `{ "kind": "release", "package": "<id>" }`: the latest release of the Craft app's own
  repository, `https://github.com/storytold/<id>/releases/download/v<version>/<id>-<version>-linux-<x86_64|aarch64>.deb`.
  The host offers a release only when GitHub publishes the asset's SHA-256; the guest downloads
  it and checks its size and SHA-256 before APT runs; or
- `{ "kind": "game", "bundle", "version", "url", "sha256", "size", "native"? }`: a game
  ([docs/game-handoff.md](../../docs/game-handoff.md)). `url`, `size` and `sha256` pin its
  WebAssembly build, a tar archive that is a GitHub release asset; `version` is its dotted
  numeric version; `bundle` names the bundle Caboose ships for it in
  [`guest/game/games`](../game/README.md); `native` optionally pins a native Linux build for
  `x86_64` and `aarch64` (`{ "url", "sha256", "size" }` each), which the bundle's
  `native_fallback` runs when no device plays the game. The app's `icon` is the bundle's
  `app_id` and its `desktopId` is `<app_id>.desktop`. Games are in the Games category.

The host validates identifiers, categories, aliases and every package source when it loads the
catalog and rejects anything else, including a game asset that is not a GitHub release asset
and a native build for another architecture name.

Every computer is offered every game: the web build runs on the device on any architecture.
The host sends the guest the archive and the native build for its own architecture, and a
computer without one installs the game to be played on a device. Installing a game downloads
and checks the archive and the native build into `/var/lib/caboose/catalog`, then, as
`caboose`, unpacks the archive into a staging directory beside
`~/.local/share/caboose/games/<id>` (at the bundle's `root`), adds the shipped bundle from
`/usr/local/share/caboose/games/<bundle>` and the native build at the program
`native_fallback` names, and swaps the staging directory in with one atomic rename. As root
it then writes `/usr/local/share/applications/<desktopId>` (`Exec=caboose-game-run <the
game's directory>`, with the version in `X-Caboose-Catalog-Version`, which is the installed
version the Library reports) and the bundle's `icon.png` as the hicolor icon
`/usr/local/share/icons/hicolor/128x128/apps/<icon>.png`. The downloads are deleted once the
game is installed. An update is the same swap, so it replaces the whole directory. Removing a
game removes the desktop entry, the directory and the icon; its saves, under the save paths
of its manifest, stay. Game installs run neither APT nor dpkg.

Debian package names and desktop ids are checked against the Debian 13 amd64 and all-arch
package indexes; Craft desktop ids and file associations against the release desktop files
named below. An empty file-type list means no association is recorded, not that the app
cannot open files. The additional `ai`, `fcproj`, `scraft` and camera-raw extensions follow
these releases: [VectorCraft v0.17.0](https://github.com/storytold/vectorcraft/blob/v0.17.0/README.md),
[FilmCraft v0.13.0](https://github.com/storytold/filmcraft/blob/v0.13.0/docs/project-files.md),
[SoundCraft v0.13.1](https://github.com/storytold/soundcraft/blob/v0.13.1/packaging/linux/ai.storyteller.soundcraft.mime.xml)
and [LightCraft v0.14.0](https://github.com/storytold/lightcraft/blob/v0.14.0/README.md).
Adobe Illustrator support depends on the file's PDF-compatible representation, RAW support
varies by camera, and project files may reference media that must also be on the computer.

caboose-host sends each app's `icons/<id>.png` with the catalog, so clients can show an app
before it is installed; a test requires an icon and a licence file for every app. The Craft
icons are the upstream 128-pixel Linux app icons from each app's release tags, from
<https://github.com/storytold>; the apps are MIT OR Apache-2.0. The upstream launcher
describes the Craft package layout at <https://github.com/storytold/craft-launcher>.

The Powder Toy's icon is the project's own, from its pinned release tag (see
`powder-toy.LICENSE.txt`), and is the bundle's `icon.png`; the game is GPL-3.0.

Platformer 3D's icon is the demo project's own, from the pinned demo commit (see
`platformer-3d.LICENSE.txt`), and is the bundle's `icon.png`; the demo and Godot Engine are
MIT. Its archive is Caboose's export of the demo (`guest/game/recipes/platformer-3d.sh`),
published as a release asset of this repository, and carries the demo's and the engine's
licences and the engine's third-party notices. Its version is the engine's version followed
by the date of the pinned demo commit.

The Debian apps' icons are their own hicolor theme icons, taken from the Debian 13 package
that ships them (the app's package, or one built from the same source such as its `-data`
package): the 256-pixel PNG scaled to 128 pixels, else the 128-pixel PNG, else the scalable
SVG rendered at 128 pixels. Each `<id>.LICENSE.txt` names the file, package and version, and
reproduces that package's `debian/copyright`, which gives the icon's copyright and licence.
To regenerate them, with Docker:

```sh
guest/catalog/extract-icons.sh
```

It runs in a pinned `debian:trixie` amd64 image against a pinned snapshot.debian.org date
(`SNAPSHOT` in the script) and finds the packages through the archive's Contents indexes, so
re-running it gives the same files. It fails if an app's desktop entry names a different icon
than `catalog.json`, or if no icon is found. Run it after adding a Debian app or changing its
packages, and move `SNAPSHOT` forward to take newer packages.

## Releases and updates

Installed apps update themselves once a day: Craft apps to their latest release, Debian apps
as APT upgrades them, and games to the version `catalog.json` pins when it is newer than the
installed one. A release's published checksum protects its integrity in transit, not against
a malicious upstream release. When a Craft release changes its desktop id or file
associations, update `catalog.json` and run the commands below.

A game changes only when its pin does. Review the upstream source and release assets first,
since a checksum does not protect against a malicious upstream release. Then change the
version and the archive's and each native build's URL, size and SHA-256 together (the sizes
from the GitHub release API, the checksums from downloaded copies), check that the shipped
bundle still matches the release (its page loads the build's files, and its manifest's save
mounts and `native_fallback` match what the build does), update the pinned values in
`apps/host/src/app-catalog-data.test.ts`, and run:

```sh
pnpm --filter caboose-host test                       # catalog validation
python3 apps/ios/scripts/document-types.py --write    # after changing file types
python3 apps/ios/scripts/test-document-types.py
```

To check an install on a deployed host, `node apps/host/scripts/check-catalog.mjs` installs
PhotoCraft and requires its window; `CABOOSE_CATALOG_APP=powder-toy` does the same for The
Powder Toy.
