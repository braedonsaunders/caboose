# Application catalog

The curated applications a computer can install on demand. The Library also discovers Debian desktop applications through the guest’s AppStream metadata and APT; see `docs/architecture.md` § Catalog. caboose-host serves the catalog
at `GET /v1/catalog` and installs, updates, rolls back and removes its apps inside the
computer (see [`apps/host`](../../apps/host/README.md#catalog-and-craft-jobs) and
`docs/architecture.md` § Catalog).

| File | What |
| --- | --- |
| `catalog.json` | The packs and apps. |
| `schema.json` | A JSON Schema describing `catalog.json`. |
| `craft-releases.json` | The reviewed Craft releases: version, URL, byte count and SHA-256 for each. |
| `icons/` | Each app's 128-pixel icon (`<id>.png`) and its licence files. |
| `extract-icons.sh` | Regenerates the Debian apps' icons from their packages. |

Each app has an `id`, `name`, `summary`, `category`, the `packs` it belongs to, an `icon`
name (the `Icon` key of its desktop entry), its `desktopId`, and `fileTypes` (`extensions` and iOS `utTypes`) for opening documents
in place. Craft apps also name their `cli` and `mcp` commands, which Craft jobs and agent
tasks use. An app's `source` is either:

- `{ "kind": "apt", "packages": [...] }`: Debian packages from the signed Debian 13
  repositories; or
- `{ "kind": "deb", "package", "version", "url", "sha256", "size" }`: a Craft release `.deb`
  from `https://github.com/storytold/<id>/releases/download/v<version>/<id>-<version>-linux-x86_64.deb`.
  The guest downloads it, checks its size and SHA-256 before APT runs, and keeps it in
  `/var/lib/caboose/catalog`, so a later update can roll back to it.

The host validates identifiers, pack membership and every package source when it loads the
catalog and rejects anything else, including a Craft URL that does not follow that pattern.
ARM64 hosts offer Debian applications only; the pinned x86_64 Craft releases and empty packs
are omitted from their catalog.

Debian package names and desktop ids are checked against the Debian 13 amd64 and all-arch
package indexes; Craft desktop ids and file associations against each pinned release's
desktop file. An empty file-type list means no association is recorded, not that the app
cannot open files. The additional `ai`, `fcproj`, `scraft` and camera-raw extensions follow
the pinned releases: [VectorCraft v0.17.0](https://github.com/storytold/vectorcraft/blob/v0.17.0/README.md),
[FilmCraft v0.13.0](https://github.com/storytold/filmcraft/blob/v0.13.0/docs/project-files.md),
[SoundCraft v0.13.1](https://github.com/storytold/soundcraft/blob/v0.13.1/packaging/linux/ai.storyteller.soundcraft.mime.xml)
and [LightCraft v0.14.0](https://github.com/storytold/lightcraft/blob/v0.14.0/README.md).
Adobe Illustrator support depends on the file's PDF-compatible representation, RAW support
varies by camera, and project files may reference media that must also be on the computer.

caboose-host sends each app's `icons/<id>.png` with the catalog, so clients can show an app
before it is installed; a test requires an icon and a licence file for every app. The Craft
icons are the upstream 128-pixel Linux app icons from each pinned release tag, from
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

## Updating a release

The host never checks for a newer release; changing a pin makes the update available for the
owner to choose. Release checksums protect integrity, not against a malicious upstream
release, so review the upstream source and release assets first. Then change the version,
URL, size and checksum together in both `catalog.json` and `craft-releases.json`, replace
the icon if it changed, and run:

```sh
pnpm --filter caboose-host test                       # catalog validation, and catalog.json against craft-releases.json
python3 apps/ios/scripts/document-types.py --write    # after changing file types
python3 apps/ios/scripts/test-document-types.py
```

To check an install on a deployed host, `node apps/host/scripts/check-catalog.mjs` installs
PhotoCraft and requires its window.
