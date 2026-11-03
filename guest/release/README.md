# Releases of the GPU and display stack

Every computer runs one release of the stack that puts its windows on the phone's GPU:
the guest Vulkan driver and its layers (both architectures, and their copies in the
Flatpak `GL.host` and `GL32.host` extensions), caboose-display and its probe,
`caboose-session`, the GPU broker, the VA-API driver, the vgem GBM backend, the patched
Xwayland package and the files they need. A driver or display change ships only as a new
release to every computer.

`caboose-release` builds, installs and reports releases. It runs as root on the host and
keeps releases in `/root/caboose-release` (`CABOOSE_RELEASES` overrides it).

| Command | What it does |
| --- | --- |
| `new ID [--from ID]` | Starts release `ID`, empty or a copy of a sealed one |
| `add ID SOURCE PATH [MODE]` | Adds a file installed at `PATH` (octal `MODE`, default 0644) |
| `capture ID COMPUTER PATH...` | Adds files as computer `COMPUTER` (its container name) has them now, with their modes |
| `deb ID DEB` | Adds a package installed with `dpkg -i` |
| `remove ID PATH` | Adds a path deleted on install |
| `seal ID NOTE...` | Runs the executor check, writes `notes`, the SBOM and `MANIFEST`, and signs it; a sealed release never changes |
| `sign ID` | Signs a sealed release's `MANIFEST` again (with a new key, or one sealed before signing) |
| `install ID [--wait S] [COMPUTER...]` | Installs on every running computer (or those named) |
| `status` | Each running computer's release, and whether a game runs there |
| `list` | The releases, sealed or open, with their notes |

A release is a directory: `files/` mirrors the paths installed in a computer, `debs/`,
`remove`, `notes`, `check/`, `sbom.spdx.json`, `MANIFEST` and `MANIFEST.sig`. The manifest lists every
other file's SHA-256, its mode and its path, and an install refuses a release that does not
match it.

## The executor check

Sealing first checks the release's 64-bit driver against the
[Linux executor](../../apps/ios/GPUStream/gfxstream/linux-executor/README.md), which stands
in for the phone: its `check.sh` runs the synchronization probe, then vkcube presenting 300
frames, in disposable containers. The check then installs the release payload in a disposable computer and starts its own
`caboose-session`, display and packaged broker launcher, requiring an authenticated `/gpu`
WebSocket upgrade. The check also runs cold and fresh-process warmed capability queries
through the packaged broker, requiring identical answers and verified cache-hit counts.
A release whose check fails is not sealed and stays open.
The check's logs and `check/result` (`PASS` or `FAIL`, then the check's summary lines) stay
in the release, and the manifest covers them. The settings are `key=value` lines in
`/root/.config/caboose-release/check.conf` (`CABOOSE_RELEASE_CHECK` overrides the path):

| Key | Is |
| --- | --- |
| `repo` | A checkout whose `check.sh` and broker run |
| `image` | The computer image the broker runs in |
| `work` | The directory the Linux executor's `build.sh` built in |
| `capability_probe` | The built `capability_queries.c` probe; packaged broker/cache handshake validation |
| `sync_check` | The synchronization probe ([sync-check](../gpu/gfxstream/driver/sync-check/README.md)), built |

## Signatures and the SBOM

`MANIFEST.sig` is the base64 Ed25519 signature over the exact bytes of `MANIFEST`, made with
OpenSSL (`openssl pkeyutl -sign -rawin`). The private key never enters the repository: it is
`/root/.config/caboose-release/release-ed25519.key.pem` (mode 0600) on the host that seals
releases, or `CABOOSE_RELEASE_KEY`. Sealing refuses to run without it, and keeps a signature
only once the public key verifies it. The public key is
[`caboose-release.pub.pem`](caboose-release.pub.pem); `caboose-release` reads it beside
itself, then from `/usr/local/share/caboose-release/`, or from `CABOOSE_RELEASE_PUB`. Install
it with the tool:

```sh
install -m 0755 guest/release/caboose-release /usr/local/sbin/caboose-release
install -D -m 0644 guest/release/caboose-release.pub.pem /usr/local/share/caboose-release/caboose-release.pub.pem
```

An install refuses a release whose signature is missing or does not verify. A new key means
committing its public key and signing each release still to be installed with `sign`.

`sbom.spdx.json` is an SPDX 2.3 software bill of materials written at sealing: the release as
a package that contains every file it installs, with its SHA-1 and SHA-256, and every Debian
package in `debs/` with its name, version, architecture and checksum (read with `dpkg-deb`).
The release's notes are its package comment. The manifest covers the SBOM, so the signature
covers it too.

Installing on a computer first checks the game gate: while a process matches
`MCC-Win64|steam_app_[0-9]|AppId=[0-9]` nothing is touched there. With `--wait S` the
computers a game holds are tried again every 30 s for up to `S` seconds. Otherwise the
release's files are copied in (owned by root, with the manifest's modes), its removals and
packages applied, Steam asked to quit if it runs, the owner's display restarted through
`caboose-session`, Steam started again if it ran, and `/etc/caboose-release` written: the
release id, the manifest's SHA-256 and the notes.

Run `python3 -m unittest guest/release/test_release.py` for the release format, signature
and SBOM tests, and the executor check's, with the check itself stood in. They need OpenSSL with Ed25519 (1.1.1 or later), and no Docker or root.
