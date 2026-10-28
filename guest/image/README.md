# Caboose guest image

Build on an amd64 Linux machine with Docker, `/dev/loop-control`, network access,
space for a 16 GiB raw image and a reflink-capable target filesystem. The builder
is privileged because it creates and mounts a loop device and chroots into the
image. It uses debootstrap to produce a clean Debian 13 system; no host sudo or
libguestfs appliance is required. Docker's storage and the output directory
should be on a filesystem with sufficient free space.

```sh
OUT_DIR=/data/caboose/disks ./guest/image/build.sh
```

This creates `base.raw`, `vmlinux`, and `initrd`. It refuses to overwrite any of
them; build into an empty directory. On failure it unmounts the guest and retains
the `.build.*` work directory for diagnosis; a retry builds a fresh image.
The disk has an ext4 root on partition 3,
matching the host's `root=/dev/vda3`. The root mounts with `noatime`;
`/home/caboose/.cache` is a 512 MiB tmpfs, shared by application caches and
cleared on a fresh boot. Keep base and overlays on XFS with reflink
or Btrfs. Existing overlays and snapshots continue to refer to their previous
base; do not replace a base underneath an existing computer. Back up and retire
that computer explicitly before deploying a different base.

If the host container mounted the disk filesystem in its own mount namespace
(as with `deploy/compose.yaml` on an ext4 host), use:

```sh
CABOOSE_HOST_CONTAINER=deploy-caboose-host-1 ./guest/image/build.sh
```

This stages the build in `/data/caboose/build` and copies it through the
container into the mounted filesystem. Both the staging directory and the
container's image paths must be empty, and the container must have no overlays.
The staging files remain available for inspection after installation.

The builder installs Xpra 6.5.5 from its upstream repository, pinned with APT,
the desktop MCP server and its accessibility helper from `guest/desktop-mcp` (which also
switches on the apps' accessibility trees), the agent runner from `guest/agentd` (with the
ACP SDK it pins), and the Bunkhouse guest agent
at a pinned source revision with appkit-desk
0.6.0. The agent listens on vsock port 5252. Xpra starts only when the host has
written its per-wake password; it does not run automatically at boot. A separate `caboose-xpra-agent.service`
provides display `:101` on port `14501` with the same token when explicitly
started by the host on demand. Both units pass Xpra `--env=NO_AT_BRIDGE=0
--start-env=GTK_A11Y=atspi` and the accessibility environment, and start each display's
accessibility bus as it comes up (`a11y.py bus`, see `guest/desktop-mcp/README.md`). Debian OS packages follow their signed
repositories at build time; the app installer pins its external releases.

The image also carries [Caboose Display](../display/README.md) (`caboose-display`,
`caboose-display-probe`, `caboose-display-ready`, built in the builder's first stage) and
`caboose-display.service`, which is installed but not enabled: Xpra stays the default.
A host that selects Caboose Display writes the token, starts `caboose-display.service`
instead of `caboose-xpra.service`, and waits for `caboose-display-ready 60`. The service
serves WebSocket port `14600`, runs Xwayland on `:110`, and writes the environment for
launched applications to `/run/caboose/display.env`. The codec passthrough VA-API driver
(guest/vaapi) is installed with it; the image loads the `udmabuf` module at boot and gives
`/dev/udmabuf` to the `caboose` group for the driver's decode surfaces (on kernels without
the module, GL players fall back to decoding locally).

## Apps

`apps.sh` is the same idempotent installer used by the image builder and existing
Debian 13 amd64 computers. To upgrade an existing guest, copy it into the guest and
run `sudo bash apps.sh`. It does not reboot the computer. Debian packages come
from its signed APT repositories; OpenCode, mise, Lazydocker and Obsidian are pinned
to upstream release assets with checked SHA-256 hashes, and npm agent versions and
their registry integrity values are pinned. Obsidian is proprietary software.
These agent CLIs are for the owner's own terminal and need the owner's account or
credentials. Agent tasks are not limited to them: the host runs any agent in the Agent
Client Protocol registry through `caboose-agentd` (`guest/agentd`), installing it into the
home directory on demand. `apps.sh` adds `uv`/`uvx` (pinned, checksum-verified) for agents
published as Python packages and `bzip2` for agents shipped as `.tar.bz2`.

| Category | Caboose lineup |
| --- | --- |
| Browsers and writing | Chromium, Firefox ESR, Obsidian, LibreOffice, Mousepad |
| Desktop tools | Thunar, Evince, Eye of GNOME, GIMP, Inkscape, VLC, Audacity, Calculator, File Roller |
| Development | VS Code, Neovim, Git, GitHub CLI, Docker, Lazygit, Lazydocker, btop, tmux, mise |
| Shell | ripgrep, fd, bat, eza, fzf, zoxide, jq, ncdu, htop, fastfetch, yt-dlp, tealdeer, ffmpeg, ImageMagick |
| Agents | Claude Code, Codex, OpenCode, Gemini CLI |
| Fonts and appearance | Inter, JetBrains Mono, Noto CJK and emoji; WhiteSur and Adwaita from the image |

Lazygit, Lazydocker, btop, Neovim and the four agents have terminal desktop
launchers in the Home grid. Docker runs inside the guest; it does not control
the host's Docker daemon. Membership in the guest's `docker` group grants root
access inside the guest. As with other guest apps, changes to group membership
take effect on a new login. The launcher icons include OpenCode's upstream mark
and recolored [Simple Icons](https://github.com/simple-icons/simple-icons) marks
(CC0); Neovim, btop and the terminal use their installed application icons.

To check a running computer from the host, install a local Xpra client with
rencodeplus and lz4 support and run:

```sh
CABOOSE_OWNER_TOKEN=... node apps/host/scripts/check-lineup.mjs
```

The check authenticates through the display relay, verifies PNG icons and opens
Calculator, btop and OpenCode, then requires a new Xpra window for each. It
leaves those windows open and does not park or restart the computer. Agents can
show a sign-in screen until configured. The check needs free capacity for three
windows; close prior instances before rerunning if an app reuses its window.

For comparison, Omarchy's [default package list](https://github.com/omacom/omarchy/blob/83f040099f80a95f1983435e20fd2f631c2f8dee/install/omarchy-base.packages)
includes foot, Neovim, Lazygit, btop, Docker, mise, fzf, ripgrep, zoxide, eza,
bat, fd, Chromium, Obsidian, LibreOffice, LocalSend, Evince, mpv, Pinta, Noto
and JetBrains Mono; its [agent launchers](https://omarchy.org/manual/ai/) install
Claude, Codex, OpenCode and many others lazily. Omarchy's hardware, Wayland,
screen-recording and local gaming utilities do not suit the microVM. LocalSend
is omitted because the default guest network fence blocks LAN discovery; the
Xpra file-transfer path is intended for moving files instead. Pinta is not in
Debian 13's repositories, so GIMP supplies image editing. This image does not
claim to install Omarchy's optional commercial apps or all its lazy agents.

To exercise KVM, the agent, Xpra authentication through the relay, the app
list, terminal launch and memory snapshots, run `apps/host/scripts/e2e.sh` against a deployed
host as described in `apps/host/README.md`. This check wakes and parks the owner
computer, so run it only when that lifecycle change is appropriate.

The owner seat enables speaker audio and disables microphone forwarding. The
guest installs PulseAudio and GStreamer’s MP3 and PulseAudio plugins. With the
computer running, `sudo bash guest/image/check-audio.sh` checks the service,
PulseAudio, plugins, shell routing and Xpra's advertised MP3 encoder; when a phone has requested
audio, it also prints its speaker state and packet count. Hearing audio still
requires a client connected with speaker playback enabled.
Login and interactive Bash shells on `:100` discover Xpra's PulseAudio server
from its X11 root property; an explicitly configured `PULSE_SERVER` is preserved,
and the separate `:101` agent seat is not redirected to the owner's speaker.

## File service

The image installs `guest/files/caboose-files.py` and `caboose-files.service`; the host starts
it as `caboose` after writing the per-wake display token. It listens on guest port 14700 and
serves home-confined file operations and inotify changes. See `docs/architecture.md` § Files
and `apps/host/README.md` for the API and real-host check. Existing computer disks need a
guest-side upgrade to install the service; rebuilding the golden image affects new disks.
