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
application it also is in `flathub`, so the Library shows it once. An app's `source` is either:

- `{ "kind": "apt", "packages": [...] }`: Debian packages from the signed Debian 13
  repositories; or
- `{ "kind": "release", "package": "<id>" }`: the latest release of the Craft app's own
  repository, `https://github.com/storytold/<id>/releases/download/v<version>/<id>-<version>-linux-<x86_64|aarch64>.deb`.
  The host offers a release only when GitHub publishes the asset's SHA-256; the guest downloads
  it and checks its size and SHA-256 before APT runs.

The host validates identifiers, categories, aliases and every package source when it loads the
catalog and rejects anything else.

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
as APT upgrades them. A release's published checksum protects its integrity in transit, not
against a malicious upstream release. When a Craft release changes its desktop id or file
associations, update `catalog.json` and run:

```sh
pnpm --filter caboose-host test                       # catalog validation
python3 apps/ios/scripts/document-types.py --write    # after changing file types
python3 apps/ios/scripts/test-document-types.py
```

To check an install on a deployed host, `node apps/host/scripts/check-catalog.mjs` installs
PhotoCraft and requires its window.
