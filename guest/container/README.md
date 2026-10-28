# Caboose computer as a container

The computer for the container runtime (`CABOOSE_RUNTIME=container` in
[`apps/host`](../../apps/host/README.md)): a Debian 13 image with the same app lineup and
guest components as the microVM image ([`guest/image`](../image/README.md)), for hosts whose
GPU a container can use but a VM cannot. That covers WSL2's paravirtual `/dev/dxg` (any
vendor), an NVIDIA GPU on Linux through the NVIDIA container toolkit, and Linux render nodes
(Intel, AMD). Without a GPU it runs on the CPU.

## Layout

| Path | What |
| --- | --- |
| `Dockerfile` | The image. A first stage compiles Caboose Display and the VA-API passthrough driver; the second installs Debian packages, `guest/image/apps.sh` and the guest components. Built with `guest/` as the context. |
| `caboose-session` | The session script the host runs with `docker exec` (installed as `/usr/local/bin/caboose-session`). |
| `chromium-gpu` | Chromium flags for the display and GPU in use (installed as `/etc/chromium.d/caboose-gpu`). |
| `chromium-seccomp.json` | An optional seccomp profile for Docker hosts that block Chromium's sandbox. |
| `check.sh` | A check for a running computer's encoders and sound. |

## Build

From the repository root:

```sh
docker build -t caboose-computer -f guest/container/Dockerfile guest
```

`caboose-computer:latest` is the image the host runs by default; set
`CABOOSE_CONTAINER_IMAGE` on the host to use another tag.

The image contains Debian 13 with Mesa (OpenGL, VA-API drivers), Xwayland, PulseAudio,
`caboose-display`, `caboose-display-probe` and `caboose-display-ready`, the Caboose VA-API
driver ([`guest/vaapi`](../vaapi/README.md)), the app lineup from `guest/image/apps.sh`, the
desktop MCP server and accessibility helper ([`guest/desktop-mcp`](../desktop-mcp/README.md)),
the agent runner ([`guest/agentd`](../agentd/README.md)), the file service
([`guest/files`](../files/README.md)), notifications
([`guest/notifications`](../notifications/README.md)), phone handoff and the `iPhone` printer
([`guest/phone`](../phone/README.md)), media handoff
([`guest/media-handoff`](../media-handoff/README.md)), and the WhiteSur theme. Its
environment switches on apps' accessibility trees (`ACCESSIBILITY_ENABLED`,
`GNOME_ACCESSIBILITY`, `QT_LINUX_ACCESSIBILITY_ALWAYS_ON`). The container's command is
`sleep infinity`; the host starts the session with `caboose-session`.

## Run

Run `caboose-host` on the Docker host with `CABOOSE_RUNTIME=container`. The host needs the
`docker` CLI and the privileges described in its README for the network fence. At the first
wake it creates the Docker network `caboose` (bridge `caboose-br0`) and fences it, then runs
the image as `caboose-owner` (`CABOOSE_CONTAINER_NAME`) with:

- `/home/caboose` on the volume or absolute host path in `CABOOSE_CONTAINER_HOME` (default
  volume `caboose-home`);
- memory and CPU limits from the computer's settings, and a 2 GiB `/dev/shm`;
- the owner's display (14600), the agent seat (14601) and the file service (14700)
  published on `127.0.0.1` only;
- the GPU chosen by `CABOOSE_GPU` (detected by default), passed into the container as
  `CABOOSE_GPU`;
- any extra arguments from `CABOOSE_CONTAINER_ARGS`.

Published ports are fixed when the container is created. The host updates the guest
components inside an existing container at wake (`guest/components`), but a container whose
display or file service ports are not published as above must be recreated from the current
image; its home volume is kept.

| `CABOOSE_GPU` | Host | The container gets | Apps render with | Caboose Display encodes with |
| --- | --- | --- | --- | --- |
| `wsl` | Windows with WSL2, any vendor | `/dev/dxg`, `/usr/lib/wsl` read-only | Mesa D3D12 | NVENC on an NVIDIA GPU (through `/usr/lib/wsl/lib`), otherwise software |
| `nvidia` | Linux with the NVIDIA container toolkit | `--gpus all`, `/dev/udmabuf` when present | the NVIDIA driver | NVENC |
| `dri` | Linux, Intel or AMD | `/dev/dri`, `/dev/udmabuf` when present | Mesa | software |
| `none` | any | nothing | Mesa software rendering | software |

The image does not install a Linux NVIDIA driver; WSL supplies `libcuda` and NVENC through
`/usr/lib/wsl/lib`, and on Linux the NVIDIA container toolkit supplies the driver's
libraries.

### `caboose-session`

The host runs `caboose-session` as root through `docker exec`. Everything it starts for the
owner runs as `caboose`, and every command is safe to repeat.

| Command | What it does |
| --- | --- |
| `start-files` | Starts the file service as `caboose` and waits until port 14700 listens. |
| `start` | Starts CUPS and configures the `iPhone` queue; starts the owner's session bus (`/run/user/1000/bus`), its notification monitor and endpoint, and the owner's Caboose Display: port 14600, Wayland socket `wayland-caboose-0`, Xwayland `:110`, its own PulseAudio, launch environment in `/run/caboose/display.env`. |
| `ready` | Waits up to 120 s for the owner's display to answer a hello with the host's token, then starts its accessibility bus. |
| `start-agent` | Starts the agent seat: its own session bus (`/run/user/1000/agent-bus`) and notification endpoint, and a Caboose Display on port 14601 with Wayland socket `wayland-caboose-agent`, Xwayland `:101`, `--x11-only --no-audio`, launch environment in `/run/caboose/agent-display.env`. Waits until it is ready, then starts its accessibility bus. |

Both displays check the token the host writes to `/run/caboose/display-token` before
`start`; the host keeps it while the container is paused and writes a new one when the
container is created or restarted.

Apps launched on the owner's display prefer Wayland and fall back to X11 through Xwayland; they play sound through the `PULSE_SERVER` in the display's launch
environment. On the agent seat apps run on Xwayland alone, so the agents' X11 tools can
drive them. Each display's own accessibility bus keeps the desktop tools and `/v1/screen`
reading one display at a time (see [`guest/desktop-mcp`](../desktop-mcp/README.md)).

The displays and notification processes log to `/home/caboose/.cache/<name>.log`
(`caboose-display.log`, `caboose-display-agent.log`, …).

### Chromium

`/etc/chromium.d/caboose-gpu` runs Chromium as a native Wayland client on the owner's
display. On WSL, Chromium on the owner's display uses software raster, because its Wayland
GPU path needs a DRM render node that WSL does not have; on the agent seat (X11) it uses
ANGLE over Mesa D3D12. Where the launch environment selects the Caboose VA-API driver
(hosts with a render node), Chromium decodes video through it, so a video reaches the phone
as its own stream.

Chromium keeps its sandbox enabled. On Docker hosts whose default seccomp policy blocks
Chromium's namespace sandbox, add `--security-opt seccomp=<absolute path to
guest/container/chromium-seccomp.json>` to `CABOOSE_CONTAINER_ARGS`. The profile is based on
the [Moby seccomp v0.2.1 default](https://github.com/moby/profiles/blob/seccomp/v0.2.1/seccomp/default.json)
(Apache-2.0), with `clone` and `unshare` allowed for user, PID and network namespaces; mount,
UTS, IPC and cgroup namespace creation stays blocked. Review it against your Docker version
and security requirements.

### Parking and restarts

Parking freezes the container (`docker pause`): memory stays in RAM and waking is immediate,
but only while Docker (and, on Windows, WSL) keeps running. After a Docker, WSL or host
restart the session is gone and the next wake starts it fresh; the home volume persists. A
cold restart from the app or console stops and starts the same container, so installed
packages and the catalog's rollback cache in its writable layer survive. Removing or
replacing the container discards them; back up the home volume separately. To pick up a new
image, remove the container and wake the computer again; the home volume is kept.

## Check

With the computer running, from the repository root:

```sh
docker exec -u root caboose-owner bash -s < guest/container/check.sh
```

It waits for the owner's display, lists the encoders `caboose-display --list-encoders`
reports and requires H.264 (and NVENC HEVC on `nvidia`, or on `wsl` with an NVIDIA GPU), and
checks that the owner display's PulseAudio answers `pactl info`. It does not restart or park
the computer.

Other checks for this image:

- `apps/host/scripts/e2e.sh` checks the host and display protocol, both seats, and parking
  (see [`apps/host`](../../apps/host/README.md#real-host-checks)).
- `apps/host/scripts/check-agent-shell.sh` runs the agent runner and the host's guest scripts
  in a Debian container.
- `docker exec -u root caboose-owner bash -s < guest/media-handoff/check.sh` checks media
  handoff.
- `docker exec -u root caboose-owner bash -s < guest/phone/check.sh` checks the phone
  commands and printer; it consumes pending handoffs.
- `guest/notifications/check-container.sh` checks the notification monitor and separate
  session buses in a disposable container.
- `guest/desktop-mcp/check-a11y.sh` runs both Caboose Display instances and the
  accessibility helper in Docker.
