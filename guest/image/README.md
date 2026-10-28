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
the desktop MCP server from `guest/desktop-mcp`, and the Bunkhouse guest agent
at a pinned source revision with appkit-desk
0.6.0. The agent listens on vsock port 5252. Xpra starts only when the host has
written its per-wake password; it does not run automatically at boot. A separate `caboose-xpra-agent.service`
provides display `:101` on port `14501` with the same token when explicitly
started by the host on demand. Software
and OS packages other than Xpra follow their repositories at build time.

To exercise KVM, the agent, Xpra authentication through the relay, the app
list, terminal launch and memory snapshots, run `apps/host/scripts/e2e.sh` against a deployed
host as described in `apps/host/README.md`. This check wakes and parks the owner
computer, so run it only when that lifecycle change is appropriate.
