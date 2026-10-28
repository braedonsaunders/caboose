# caboose-host

Work in progress: the API, guest integration and real-machine end-to-end check
are not yet verified against a Caboose image. This package is not ready to run
as a persistent service or expose to clients.

Install Node 22 and pnpm, then from the repository root run `pnpm install`,
`pnpm --filter caboose-host typecheck`, and `pnpm --filter caboose-host test`.

The environment variables are listed in `.env.example`. The host needs access
to KVM, a Cloud Hypervisor binary, and a Caboose image containing `base.raw`,
`vmlinux`, and `initrd`. Networking creates a named TAP and configures IPv4
forwarding, masquerading and filter rules; it requires root or passwordless
sudo for `ip`, `iptables` and `sysctl`. The guest can access networks reachable
from the host. Use a dedicated trusted host and network namespace. HTTPS/WSS
must be provided by a trusted reverse proxy before traffic crosses a network;
the host service itself serves unencrypted HTTP/WebSocket.

The unverified user-service template is `systemd/caboose-host.service`. Set
`CABOOSE_HOST_DIR` to the absolute path of `apps/host` and `CABOOSE_NODE` to
the absolute Node executable in `~/.config/caboose/host.env`, in addition to the
variables in `.env.example`; set the file mode to 0600. A user service also
needs a running user systemd manager, KVM group access, and non-interactive
privileges for the network setup. `CABOOSE_BIND=0.0.0.0` listens on every IPv4
interface; the service does not terminate TLS.

The guest is fenced: it can open no connection to the host, and it reaches only the
public internet, not private, link-local (cloud metadata), CGNAT or Tailscale
addresses. Set `CABOOSE_GUEST_LAN=allow` to let a self-hosted computer reach your LAN.

`CABOOSE_OWNER_TOKEN=... apps/host/scripts/e2e.sh` uses the local Xpra client
to authenticate an Xpra hello over the relay, parks, resumes, and repeats.
Set `CABOOSE_URL` when testing a different host. This check is not yet validated
against the Caboose guest image.

## Self-host with Docker

On an amd64 Linux machine, install Docker and Compose, enable hardware
virtualization and make `/dev/kvm` available. Docker must be able to run
privileged containers. Allow space for the golden image, overlays and memory
snapshots; the default sparse XFS volume has a 400 GiB maximum and grows on
use. State is under `/data/caboose` by default, including `disks.xfs.img` when
the underlying filesystem is not XFS or Btrfs. Set `CABOOSE_STATE_DIR` in
`deploy/.env` to use a different absolute path. If using a loop image, its
filesystem is mounted inside the container at `/data/caboose/disks`, not on
the host. Back up the entire state directory while the container is stopped.
Do not run multiple containers against the same state directory.

Create `deploy/.env` with mode 0600 containing a long random owner token:

```sh
umask 077
printf 'CABOOSE_OWNER_TOKEN=%s\n' "$(openssl rand -hex 32)" > deploy/.env
```

Then start from the repository root:

```sh
docker compose -f deploy/compose.yaml up -d --build
```

The service listens on host loopback port 7310 by default. Set
`CABOOSE_PUBLISH_ADDRESS` in `deploy/.env` to a specific host address (or
`0.0.0.0` for all interfaces) when a trusted reverse proxy or network needs
access. HTTP carries the bearer token in cleartext: use HTTPS/WSS at a trusted
proxy for network access. The container is privileged for KVM, loop mounts,
and TAP networking; only run it on a trusted host. Its private Docker network
namespace contains its TAP, forwarding and NAT rules, while Docker itself
manages the published port on the host. The guest can reach networks available
to the container. Cloud Hypervisor is pinned to the amd64 v49.0 static release.

The service can start and report health before a guest image is installed, but
cannot wake a computer until `base.raw`, `vmlinux`, and `initrd` are present in
its disk root. Once the Caboose image builder is available, copy its output
into the mounted disk root (for example, `docker cp base.raw
$(docker compose -f deploy/compose.yaml ps -q caboose-host):/data/caboose/disks/base.raw`,
and likewise for the kernel and initrd). The guest image and end-to-end flow
are not yet verified. `apps/host/scripts/check-container.sh` checks the real
container's network namespace, TAP/NAT, KVM access, reflinks and authenticated
health. The `e2e.sh` check above requires the Xpra client and a built guest;
its first wake is cold only if no saved snapshot exists.

To rotate the token, replace `CABOOSE_OWNER_TOKEN` in `deploy/.env` with a new
random value, then run `docker compose -f deploy/compose.yaml up -d` to
recreate the service. Update every client; the old token stops working. Keep
this file private and never commit it. The token is also visible to Docker
administrators through container configuration.
