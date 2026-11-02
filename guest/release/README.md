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
| `seal ID NOTE...` | Writes `notes` and `MANIFEST`; a sealed release never changes |
| `install ID [--wait S] [COMPUTER...]` | Installs on every running computer (or those named) |
| `status` | Each running computer's release, and whether a game runs there |
| `list` | The releases, sealed or open, with their notes |

A release is a directory: `files/` mirrors the paths installed in a computer, `debs/`,
`remove`, `notes` and `MANIFEST`. The manifest lists every file's SHA-256, its mode and its
path, and an install refuses a release that does not match it.

Installing on a computer first checks the game gate: while a process matches
`MCC-Win64|steam_app_[0-9]|AppId=[0-9]` nothing is touched there. With `--wait S` the
computers a game holds are tried again every 30 s for up to `S` seconds. Otherwise the
release's files are copied in (owned by root, with the manifest's modes), its removals and
packages applied, Steam asked to quit if it runs, the owner's display restarted through
`caboose-session`, Steam started again if it ran, and `/etc/caboose-release` written: the
release id, the manifest's SHA-256 and the notes.

Run `python3 -m unittest guest/release/test_release.py` for the release format tests. They
need no Docker or root.
