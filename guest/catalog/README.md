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
