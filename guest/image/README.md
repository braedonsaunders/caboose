# Caboose guest image

The computer's golden image for the microVM runtime: a Debian 13 (trixie, amd64 or arm64) system that
`caboose-host` boots with Cloud Hypervisor. The builder produces three files, `base.raw`,
`vmlinux` and `initrd`; the host clones `base.raw` copy-on-write for the computer's disk and
boots it with `root=/dev/vda3 rw`. The container runtime uses
[`guest/container`](../container/README.md) instead, with the same app lineup and guest
components.

## Layout

| Path | What |
| --- | --- |
| `build.sh` | Builds the builder image and runs it. Entry point. |
| `Dockerfile` | The builder: a first stage compiles Caboose Display and the VA-API passthrough driver; the second has debootstrap and copies the guest components. |
| `build-inside.sh` | Inside the builder: partitions and formats the raw disk, runs debootstrap, chroots into `configure-guest.sh`, and extracts the kernel and initrd. |
| `make-system-image.sh` | Packs a prepared root’s `/usr` and `/opt` into an LZ4HC-compressed EROFS image without modifying the root. |
| `configure-guest.sh` | Inside the chroot: packages, the `caboose` user, every guest component, theme, fonts and boot configuration. |
| `apps.sh` | The app lineup installer, shared with the container image and usable on a running computer. |
| `desktop-apps.sh`, `desktop-apps.tsv` | Official desktop package installer and exact version/SHA-256 pins for both architectures. |
| `check-desktop-apps.sh` | Disposable Debian install and desktop window check. |
| `check-audio.sh` | A check for a running computer's sound. |

## Build

Build on a native amd64 or arm64 Linux machine with Docker, `/dev/loop-control`, network access, space for a
60 GiB sparse raw image, and a reflink-capable target filesystem (XFS with reflink, or Btrfs).
The output matches the build machine; it does not cross-compile. ARM64 kernels are
written as an uncompressed Linux Image. Rust builds use two jobs by default
(`CARGO_BUILD_JOBS` Docker build argument). The builder runs privileged because it creates and mounts a loop device and chroots into the
image; it needs no host `sudo` or libguestfs. Docker's storage and the output directory need
enough free space.

```sh
OUT_DIR=/data/caboose/disks ./guest/image/build.sh
```

`OUT_DIR` defaults to `/data/caboose/disks`. The build refuses to overwrite `base.raw`,
`vmlinux` or `initrd`; build into an empty directory. On failure it unmounts the image and
keeps the `.build.*` work directory in the output directory for diagnosis; a retry builds a
fresh image.

When the host runs under `deploy/compose.yaml` and its disk filesystem is mounted only inside
the container (a loop-mounted XFS image on an ext4 host), build into the container instead:

```sh
CABOOSE_HOST_CONTAINER=deploy-caboose-host-1 ./guest/image/build.sh
```

This stages the build in `/data/caboose/build` and copies it through the container into
`/data/caboose/disks`. The container's image files must not exist and its `overlays`
directory must be empty. The staged files remain for inspection.

The disk is a 60 GiB sparse GPT image with a Btrfs root (label `caboose`) on partition 3,
mounted with `compress-force=zstd:1,discard=async,noatime`. Existing ext4 computers
retain their filesystem. Compression savings vary with the workload; sparse logical
capacity is not a reservation of physical host storage. Discard reclamation requires
support throughout the runtime and backing filesystem.
`/home/caboose/.cache` is a 512 MiB tmpfs, shared by application caches and cleared at every
cold boot. Keep the base and overlays on XFS with reflink or on Btrfs. A computer's overlay
and snapshot refer to the base they were made from: do not replace a base underneath an
existing computer. A new base reaches new computers only; update an existing one from inside
it (see [Updating a running computer](#updating-a-running-computer)).

## What the image contains

- **System.** Debian 13 from its signed repositories, the `linux-image-cloud-amd64` or `linux-image-arm64` kernel,
  systemd, D-Bus with a user session, the `caboose` user (uid 1000, passwordless `sudo`,
  lingering enabled so its user manager runs at boot), Node 22 from NodeSource and VS Code
  from Microsoft's repository.
- **Guest agent.** The appkit-desk guest agent from Bunkhouse at a pinned revision, with the
  appkit-desk 0.6.0 protocol files, on vsock port 5252 (`desk-guest-agent.service`,
  `desk-vsock-bridge.service`). The host runs every guest command through it. It runs as root
  with root's home; commands for the owner are started with `runuser -u caboose`.
- **Caboose Display** ([`guest/display`](../display/README.md)): `caboose-display`,
  `caboose-display-probe` and `caboose-display-ready` in `/usr/local/bin`, Xwayland, and two
  units the host starts (they are not enabled):

  | Unit | Port | Wayland socket | Xwayland | Launch environment |
  | --- | --- | --- | --- | --- |
  | `caboose-display.service` (owner's display) | 14600 | `wayland-caboose-0` | `:110` | `/run/caboose/display.env` |
  | `caboose-display-agent.service` (agent seat) | 14601 | `wayland-caboose-agent` | `:101` | `/run/caboose/agent-display.env` |

  Both run as `caboose` and check the per-wake token the host writes to
  `/run/caboose/display-token` before starting them; `caboose-display-ready [TIMEOUT] [PORT]`
  waits until an instance answers a hello made with it and has written its launch environment. The owner's display runs its own
  PulseAudio, and its launch environment gives apps `PULSE_SERVER`, the Wayland socket,
  Xwayland's `DISPLAY` and `XAUTHORITY`, and toolkit hints that prefer Wayland and fall back
  to X11. The agent seat runs `--no-audio`: its apps run the same way, it plays no sound, and
  it has its own D-Bus session bus (`/run/user/1000/agent-bus`). Each instance keeps its X
  authority, Xwayland shim, PulseAudio socket and control socket under
  `/run/user/1000/caboose-display/<wayland socket>/`. As each display becomes ready, its
  unit starts that seat's accessibility bus (`a11y.py bus`).
- **Video passthrough.** The Caboose VA-API driver ([`guest/vaapi`](../vaapi/README.md)) in
  `/usr/lib/<architecture-triplet>/dri/caboose_drv_video.so`. The image loads the `udmabuf` module
  at boot and gives `/dev/udmabuf` to the `caboose` group for the driver's decode surfaces; on
  a kernel without the module, GL players decode locally.
- **Guest components**, each installed by its own `install.sh` or files:
  - [`guest/desktop-mcp`](../desktop-mcp/README.md): the agents' desktop MCP server and
    `/opt/caboose/a11y.py`, with apps' accessibility trees switched on;
  - [`guest/agentd`](../agentd/README.md): the agent runner in `/opt/caboose/agentd`;
  - [`guest/files`](../files/README.md): the file service and `caboose-files.service`
    (installed, started by the host at each wake);
  - [`guest/terminal`](../terminal/README.md): the terminal service and
    `caboose-terminal.service` (enabled);
  - [`guest/notifications`](../notifications/README.md): the owner's notification monitor
    (`caboose-notifications.service`, enabled) and the notification endpoints and agent bus
    the display units require;
  - [`guest/phone`](../phone/README.md): `caboose-open`, `caboose-share`, Thunar's **Share to
    iPhone** action and the `iPhone` CUPS queue (`cups.service` and
    `caboose-phone-printer.service`, enabled);
  - [`guest/game`](../game/README.md): `caboose-game-run` and the game bundles Caboose ships,
    in `/usr/local/share/caboose/games`.
- **Appearance.** WhiteSur GTK, icon and cursor themes at pinned commits (dark), Inter and
  JetBrains Mono as the default fonts with Noto CJK and colour emoji as fallbacks, and
  `QT_QPA_PLATFORMTHEME=gtk3`.

The builder does not copy [`guest/media-handoff`](../media-handoff/README.md), so images
built by `build.sh` do not include media handoff; install it on a running computer with
`guest/media-handoff/install.sh` (see [Updating a running computer](#updating-a-running-computer)).

## Apps

`apps.sh` installs the lineup in a Debian 13 amd64 or arm64 guest or chroot. It is idempotent, and
the image builder, the container image and a running computer all use it. Debian packages
come from the signed repositories; OpenCode, mise, Lazydocker, uv and Obsidian are pinned to
upstream release assets with checked SHA-256 hashes; the npm agents are pinned by version
and registry integrity. Obsidian is proprietary software; amd64 uses its `.deb`, arm64 its pinned Electron archive.

| Category | Lineup |
| --- | --- |
| Browsers and writing | Chromium, Firefox ESR, Obsidian, LibreOffice, Mousepad |
| Desktop tools | Xfce Terminal, Thunar, Evince, KeePassXC, File Roller, mpv |
| Development | VS Code, Neovim, Git, GitHub CLI, delta, Docker and Compose, Lazygit, Lazydocker, btop, tmux, mise, Node 22, uv |
| Shell | ripgrep, fd, bat, eza, fzf, zoxide, jq, tree, ncdu, htop, fastfetch, yt-dlp, tealdeer, ffmpeg, ImageMagick |
| Desktop AI | Claude Desktop (Claude Code), ChatGPT Linux preview (Codex) |
| Agent CLIs | Claude Code CLI, Codex CLI, OpenCode, Gemini CLI |
| Rendering | Mesa Vulkan and OpenGL software drivers |
| Fonts | Inter, JetBrains Mono, Noto (core, CJK, colour emoji) |

The official [Claude Desktop](https://code.claude.com/docs/en/desktop-linux) and
[ChatGPT Linux preview](https://learn.chatgpt.com/docs/linux/linux-app) Debian packages
are pinned in `desktop-apps.tsv` by version and SHA-256 for amd64 and arm64. The installer
checks package identity and lets apt resolve dependencies. Vendor desktop entries, URI
handlers, icons, sandbox settings and signed apt repository registration remain intact;
subsequent system package updates can update the clients. The terminal launchers are
named **Claude Code CLI** and **Codex CLI**. Each desktop client requires the owner's
sign-in. Cowork's nested KVM/QEMU runtime is not included or supported by this image. Run `guest/image/check-system-image.sh` on Linux to check image creation,
extraction, source preservation and overwrite refusal.

The x86_64-only Craft packages are absent from the ARM64 catalog. Optional applications are installed from the host's catalog ([`guest/catalog`](../catalog/README.md)).

Lazygit, Lazydocker, btop, Neovim and the four agents have desktop launchers that open them in
Xfce Terminal, so they appear in the app's Home grid. The launcher icons are OpenCode's
upstream mark and recoloured [Simple Icons](https://github.com/simple-icons/simple-icons)
marks (CC0), fetched at pinned commits with checked hashes; Neovim, btop and Codex use
installed icons. The agent CLIs are for the owner's own terminal and need the owner's
account or credentials. Agent tasks are not limited to them: the host runs any agent in the
Agent Client Protocol registry through [`caboose-agentd`](../agentd/README.md), installing it
into the home directory on demand; `uv`/`uvx` and `bzip2` are there for agents published as
Python packages and `.tar.bz2` archives.

Docker runs inside the guest and does not control the host's Docker daemon. `caboose` is in
the guest's `docker` group, which grants root inside the guest; group changes take effect on
a new login.

## Updating a running computer

A computer keeps its own disk, so packages and components change from inside it. From a
checkout copied into the computer, as root:

```sh
bash guest/image/apps.sh                   # the app lineup; also installs media handoff from the checkout
sh guest/desktop-mcp/install.sh
sh guest/agentd/install.sh
sh guest/media-handoff/install.sh
```

None of these reboots the computer. The agent runner, file service, notifications, phone handoff and `caboose-game-run` are
updated by the host itself through [`guest/components`](../components/README.md);
[`guest/display`](../display/README.md) describes updating Caboose Display.

## Checks

`bash guest/image/check-desktop-apps.sh` builds a disposable Debian 13 image on the native
architecture, installs both pinned clients twice, validates their desktop entries and
launches the vendor entries as an unprivileged user under Xvfb and D-Bus. It requires a
visible window from each client, caps the display container at 2 CPUs and 2 GiB,
uses the container Chromium namespace seccomp policy,
and removes its container and tagged test image on exit. Run on both native amd64 and
arm64 hosts to cover both packages. This checks installation and first-window startup;
it does not verify account sign-in, agent execution, or Caboose Display integration.
It does not mount the owner's home or touch a running computer.


`check-audio.sh`, run as root inside a running computer, checks that the owner's display is
active, that its launch environment names a `PULSE_SERVER` that `pactl info` reaches, and,
when the agent seat is running, that the seat's launch environment has no `PULSE_SERVER`. It
plays nothing and restarts nothing. Hearing sound needs a client connected with sound on.

Against a deployed host (see [`apps/host`](../../apps/host/README.md#real-host-checks)):

- `apps/host/scripts/e2e.sh` wakes the computer, says hello to both displays through the
  relay, checks the app list and its icons, launches the terminal, parks and resumes. It
  changes the computer's lifecycle, so run it only when that is acceptable.
- `node apps/host/scripts/check-lineup.mjs` opens Mousepad, btop and OpenCode and requires a
  new window for each. It leaves them open and does not park; close earlier instances first
  if an app reuses its window. Agents can show a sign-in screen until configured.
- `node apps/host/scripts/check-catalog.mjs` installs PhotoCraft from the catalog and
  requires a new window, which exercises Mesa software rendering.

The components have their own checks: `guest/desktop-mcp/check-a11y.sh` (Docker),
`guest/notifications/check.sh` and `check-container.sh`, `guest/phone/check.sh`,
`guest/game/check.sh`, `guest/media-handoff/check.sh`, `guest/files/check-service.py` and
`guest/terminal/check-service.py`.

## Building an EROFS system image

On Linux with `erofs-utils` installed, `guest/image/make-system-image.sh ROOT OUTPUT`
creates and checks an EROFS image containing the prepared root's `usr` and `opt`.
It refuses to replace an existing output and leaves the source unchanged. The image
uses LZ4HC level 12 compression with 64 KiB physical clusters, served through
read-only virtio-block. To build a complete split image into a separate empty directory, set
`CABOOSE_SPLIT_SYSTEM=1 OUT_DIR=/path/to/version ./guest/image/build.sh`. It contains
`base.raw`, `vmlinux`, `initrd`, and `system.erofs`. On boot, initramfs mounts the
image read-only and overlays `/usr` and `/opt` with writable data on the computer's
writable root disk. The host selects this format with `CABOOSE_SPLIT_IMAGE`; existing disks
are not changed. The four files are one version and must remain available unchanged
for computers that use it. Run `guest/image/check-system-image.sh` on Linux to check image creation,
extraction, source preservation and overwrite refusal.

`sudo guest/image/check-compressed-storage.sh` checks the actual 60 GiB sparse GPT
layout, Btrfs compression with a 16 MiB text fixture, and loop-device discard with
a 32 MiB payload. It needs Linux, loop devices, Btrfs tools, util-linux and Python 3.
Its measured allocation deltas describe those fixtures, not arbitrary workloads.

`sudo guest/image/check-system-overlay.sh` checks read-only compressed EROFS and
persistent overlay writes on disposable ext4 and Btrfs upper filesystems. It needs
Linux, loop devices, mount permissions, erofs-utils, e2fsprogs and btrfs-progs.

`guest/image/check-compressed-boot.sh IMAGE_DIRECTORY amd64|arm64` boots a built
split image under QEMU software emulation, with a temporary writable snapshot and
no guest network. It checks Btrfs root mounting, compressed EROFS and writable
system overlays. It needs the matching QEMU system emulator, initramfs-tools-core,
cpio and timeout. Hosted split-image CI runs this on both architectures.

On a split microVM, run `sudo guest/image/check-split-system.sh prepare`, cold-restart
the computer, then run `sudo guest/image/check-split-system.sh verify` to check that a
write persists in the upper layer while the EROFS lower stays unchanged.

On a microVM with `CABOOSE_VM_DEPOT`, `sudo guest/image/check-vm-depot.sh` checks
that the Flatpak repository is mounted via read-only virtio-fs and rejects a write.
