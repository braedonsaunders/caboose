# WSL GPU computer

Build from the repository root with Docker on an NVIDIA WSL2 host:

```sh
docker build -t caboose-computer:gpu -f guest/container/Dockerfile guest
```

The image uses Debian 13, the signed Xpra repository at version 6.5.5, Mesa,
the guest app installer, and Xpra NVENC with PyCUDA. `CABOOSE_GPU=wsl` selects
Mesa D3D12 and enables NVENC when WSL exposes NVIDIA; `nvidia` uses native
NVIDIA, `dri` uses a Linux render node, and `none` uses software rendering. It extracts
the signed Debian `python3-pycuda` package and installs its runtime libraries
without Debian's full CUDA development toolkit and kernel driver: WSL supplies
`libcuda` and NVENC through `/usr/lib/wsl/lib`. It does not install a Linux
NVIDIA driver into WSL.

The host starts the container with `/dev/dxg` and `/usr/lib/wsl` passed through,
mounts a persistent home, and runs `caboose-session` to start Xpra. The owner
seat is `:100` on WebSocket port 14500; the agent seat starts lazily on `:101`
and port 14501. Both use `/run/caboose/xpra-token`. `caboose-session ready`
waits for Xpra to answer, and `start` and `start-agent` are safe to repeat.
Like the microVM's units, `caboose-session` starts Xpra with the apps' accessibility
switched back on (`--env=NO_AT_BRIDGE=0 --start-env=GTK_A11Y=atspi`, and
`ACCESSIBILITY_ENABLED`, `GNOME_ACCESSIBILITY` and `QT_LINUX_ACCESSIBILITY_ALWAYS_ON`, also
in the image's environment) and starts each display's own accessibility bus before any app
(`a11y.py bus`), so the desktop tools and `/v1/screen` read each display separately even
though both share the container's session bus. See `guest/desktop-mcp/README.md`; its
`check-a11y.sh` exercises this under Docker without a GPU.

The image also carries [Caboose Display](../display/README.md), built in the
Dockerfile's first stage. `caboose-session start-display` starts it (WebSocket `14600`,
Wayland `wayland-caboose-0`, Xwayland `:110`; with `CABOOSE_GPU=wsl` it can use NVENC
through `/usr/lib/wsl/lib`), and `caboose-session ready-display` waits until it answers
a hello made with the per-wake token. Launchers read the application environment from
`/run/caboose/display.env` (sh syntax), which also selects the codec passthrough VA-API
driver (guest/vaapi, built in the same stage and installed with it) for those applications;
on a host with a render node the host passes `/dev/udmabuf` for its decode surfaces. Under Caboose Display Chromium runs as a native
Wayland client; on WSL with software raster, because its Wayland GPU path needs a DRM
render node WSL does not have. Xpra remains the default display.

With the host session running, run `docker exec -u root caboose-owner bash -s <
guest/container/check.sh` to check the live Xpra encoder and MP3 dependencies.
Use `apps/host/scripts/e2e.sh` to check the host/display protocol and parking.
The image also installs the agent runner (`guest/agentd/install.sh`), which runs any
Agent Client Protocol agent for the host's tasks; `apps/host/scripts/check-agent-shell.sh`
checks it in a Debian container. It installs media handoff (`guest/media-handoff/install.sh`); check it with
`docker exec -u root caboose-owner bash -s < guest/media-handoff/check.sh`.
Docker pause retains RAM only while Docker and WSL remain running; after a
restart, home files persist but the process tree does not.

Chromium keeps its sandbox enabled. On Docker hosts whose default seccomp policy
blocks Chromium's namespace sandbox, use `--security-opt seccomp=<absolute path
to guest/container/chromium-seccomp.json>` in `CABOOSE_CONTAINER_ARGS`. This
profile is based on the [Moby seccomp v0.2.1 default](https://github.com/moby/profiles/blob/seccomp/v0.2.1/seccomp/default.json)
(Apache-2.0), with clone/unshare allowed for user, PID and network namespaces;
mount, UTS, IPC and cgroup namespace creation remains blocked. It must be
reviewed against the Docker version and local security requirements.

## File service

The image installs `guest/files/caboose-files.py`. `caboose-session start-files` starts it
as `caboose` after the host writes the wake token; the host publishes port 14700 on loopback
only. See `docs/architecture.md` § Files and `apps/host/README.md` for the API and checks.
Recreate a container from the updated image to install the service; its home volume remains.
