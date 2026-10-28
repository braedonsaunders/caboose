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

With the host session running, run `docker exec -u root caboose-owner bash -s <
guest/container/check.sh` to check the live Xpra encoder and MP3 dependencies.
Use `apps/host/scripts/e2e.sh` to check the host/display protocol and parking.
The image also installs media handoff (`guest/media-handoff/install.sh`); check it with
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
