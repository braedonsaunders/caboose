# WSL GPU computer

Build from the repository root with Docker on an NVIDIA WSL2 host:

```sh
docker build -t caboose-computer:gpu -f guest/container/Dockerfile guest
```

The image uses Debian 13, the signed Xpra repository at version 6.5.5, Mesa's
D3D12 driver, the guest app installer, and Xpra NVENC with PyCUDA. It extracts
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
Docker pause retains RAM only while Docker and WSL remain running; after a
restart, home files persist but the process tree does not.
