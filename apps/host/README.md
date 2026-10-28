# caboose-host

Work in progress: the host has been checked against a Caboose guest on a KVM
host, but the wider product and deployment configurations are still being tested.

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

## Computer management

The web console and iOS Settings use the same authenticated API:
`GET /v1/computer`, `PATCH /v1/computer/settings`, and
`POST /v1/computer/restart`. Status polling never wakes or leases the computer.
The full response and request contract is in `../../docs/architecture.md`.

Name, memory, CPUs and idle timeout are stored in `caboose.json` under
`CABOOSE_IMAGE_ROOT`. Saves use an atomic rename and mode 0600. Environment values
are defaults when no saved value exists; saved settings override them on startup.
Invalid or unreadable settings fail startup rather than silently reverting. Back
up this file with the disks. Do not edit it while the host is running.

Name and idle timeout changes apply immediately. CPU and memory changes take effect
on a cold restart; resuming a saved-memory snapshot retains its previous resources.
The response reports `activeResources` and `restartRequired`, including while the
machine is parked. An older snapshot without resource metadata has unknown active
resources until restarted. Applied resources are saved beside the disk as
`overlays/owner.resources.json`.

Restart requires JSON `{ "confirm": true }`, closes client connections and ends
agent tasks, discards open application memory, and boots the existing disk. Save
documents first. It does not restart the Linux host or delete the computer disk.
The HTTP response waits for the computer's display to be ready; allow 300 seconds.
Concurrent restart requests return 409. Park instead preserves application memory.
Restart attempts a short disk flush, but an unresponsive guest can still be
restarted. If the flush fails, the result retains a warning in `lastError`; as with
a power interruption, the filesystem may need journal recovery and unsaved writes
can be lost.

The host serves the compiled `apps/web/dist` at its root, or the directory selected
by `CABOOSE_WEB_ROOT`. Static assets and SPA routes are public; every `/v1` request
requires the owner bearer token. Missing web assets return 404. The Docker image
builds and includes the web app; a host-only checkout can still use the API without it.
Do not point `CABOOSE_WEB_ROOT` at a source or data directory.

Run the management contract check against a real host (Node 22+):

```sh
export CABOOSE_URL=https://computer.example.com
# Supply CABOOSE_OWNER_TOKEN through your private environment.
node apps/host/scripts/check-management.mjs
node apps/host/scripts/check-management.mjs --write
# This discards the guest's unsaved application state:
node apps/host/scripts/check-management.mjs --restart
```

The default check is read-only; `--write` saves the existing name unchanged;
`--restart` verifies a real cold boot and applied resources. For a device check,
open Chromium, save a document, change CPU/RAM in Settings, verify the pending
restart banner, and restart. Confirm the disk document remains, the old open
applications are gone, and the display reconnects with the new resources. These
real-machine checks require the built guest and are separate from unit tests.

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
Set `CABOOSE_URL` when testing a different host. The local Xpra client must
support the rencodeplus packet encoder and lz4 compressor. The check also
verifies that the app list contains PNG icons.

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

The Docker build compiles both `caboose-host` and `caboose-web` from the workspace
lockfile. It packages the console at `/app/apps/web/dist`, which the host serves
by default; no separate web server or port is needed. Open `http://localhost:7310`
on the server, or your HTTPS proxy URL, and enter the owner token. The console
keeps the token in browser session storage; the token is supplied only at runtime,
never during the image build. For a source checkout, build the console with
`pnpm --filter caboose-web build` before starting the host.

The service listens on host loopback port 7310 by default. Set
`CABOOSE_PUBLISH_ADDRESS` in `deploy/.env` to a specific host address (or
`0.0.0.0` for all interfaces) when a trusted reverse proxy or network needs
access. HTTP carries the bearer token in cleartext: use HTTPS/WSS at a trusted
proxy for network access. The container is privileged for KVM, loop mounts,
and TAP networking; only run it on a trusted host. Its private Docker network
namespace contains its TAP, forwarding and NAT rules, while Docker itself
manages the published port on the host. The guest can reach networks available
to the container. Cloud Hypervisor is pinned to the amd64 v54.0 static release.

The service can start and report health before a guest image is installed, but
cannot wake a computer until `base.raw`, `vmlinux`, and `initrd` are present in
its disk root. Once the Caboose image builder is available, copy its output
into the mounted disk root (for example, `docker cp base.raw
$(docker compose -f deploy/compose.yaml ps -q caboose-host):/data/caboose/disks/base.raw`,
and likewise for the kernel and initrd). The container deployment has not yet
been verified end to end. `apps/host/scripts/check-container.sh` checks the real
container's network namespace, TAP/NAT, KVM access, reflinks, authenticated
health and bundled console (HTML, compiled assets, SPA routing and API auth).
The `e2e.sh` check above requires the Xpra client and a built guest;
its first wake is cold only if no saved snapshot exists.

To rotate the token, replace `CABOOSE_OWNER_TOKEN` in `deploy/.env` with a new
random value, then run `docker compose -f deploy/compose.yaml up -d` to
recreate the service. Update every client; the old token stops working. Keep
this file private and never commit it. The token is also visible to Docker
administrators through container configuration.
