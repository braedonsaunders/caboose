# Application catalog

`catalog.json` lists the optional apps and packs. `schema.json` describes its shape;
the host validates identifiers, pack membership and all package sources before use.
Debian package names and desktop IDs were checked in the Debian 13 amd64 and all-arch
package indexes. Debian packages use the signed stable repository; Craft .debs have fixed
versions, URLs, byte counts and SHA-256 hashes from their `SHA256SUMS.txt` and GitHub
release asset metadata. GridCraft 0.12.1 was also downloaded and hashed independently.
`craft-releases.json` retains the original release research.

The Craft icons are the upstream 128-pixel Linux app icons from each pinned release tag,
from <https://github.com/storytold>; the apps are MIT OR Apache-2.0. Desktop IDs and
file associations are checked against each pinned upstream desktop file. Empty file type
lists mean no association has been recorded, not that the app cannot open files.

To update a release, review the upstream source and release assets, change the version,
URL, size and checksum together, replace its icon if appropriate, and run the host tests.
The host never checks for a newer release; a pin change only makes an update available
for the owner to choose. Release checksums protect integrity, not against a malicious
upstream release. The upstream launcher describes its package layout at
<https://github.com/storytold/craft-launcher>.

The additional `ai`, `fcproj`, `scraft` and camera-raw extensions are grounded in the
pinned releases: [VectorCraft v0.17.0](https://github.com/storytold/vectorcraft/blob/v0.17.0/README.md),
[FilmCraft v0.13.0](https://github.com/storytold/filmcraft/blob/v0.13.0/docs/project-files.md),
[SoundCraft v0.13.1](https://github.com/storytold/soundcraft/blob/v0.13.1/packaging/linux/ai.storyteller.soundcraft.mime.xml),
and [LightCraft v0.14.0](https://github.com/storytold/lightcraft/blob/v0.14.0/README.md).
AI support depends on the PDF-compatible representation; RAW support varies by camera.
Project files may reference media separately, which must also be available on the computer.
