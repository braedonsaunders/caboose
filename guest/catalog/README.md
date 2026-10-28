# Craft release research

`craft-releases.json` records candidate Debian amd64 release assets for the Craft
App Suite. The SHA-256 values come from each release's `SHA256SUMS.txt`; sizes
were checked against the GitHub release asset metadata. GridCraft 0.12.1 was
also downloaded and hashed independently. These records are research inputs,
not an installable catalog: their metadata, installer, and user interface are
not yet implemented. Do not install an entry solely because it appears here.

The upstream launcher documents its Linux package layout and distribution at
<https://github.com/storytold/craft-launcher>. Each pin must be reviewed before
it is exposed to users, including package contents, dependencies, desktop IDs,
licensing and application behavior. Release checksums protect integrity, not
against malicious upstream releases.
