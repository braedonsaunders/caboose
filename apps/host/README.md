# caboose-host

The server half of Caboose. `caboose-host` is a TypeScript service on Node 22 that runs on
Linux or Apple Silicon macOS, runs computers (Debian 13 guests, the owner's and any others made in the
console), and gives the iOS app and the web console one authenticated API for them. It wakes
a computer on demand, parks it when idle, relays its two Caboose Display instances over
WebSocket, and runs apps, agent tasks, file operations and catalog installs inside it. The HTTP contract is in
[`docs/architecture.md`](../../docs/architecture.md); the display protocol it relays is in
[`docs/display.md`](../../docs/display.md).

## Layout

| Path | What |
| --- | --- |
| `src/index.ts`, `src/config.ts` | Startup and the environment it reads. |
| `src/server.ts`, `src/lifecycle.ts` | The HTTP and WebSocket API, the owner and phone token checks, routing to each computer, and the wake/lease/park state machine. |
| `src/computers.ts` | The computers a host runs, phone sign-ins and pairing codes. |
| `src/driver.ts` | The microVM runtime: Cloud Hypervisor or Virtualization.framework through `@braedonsaunders/appkit-desk`, parked with a memory snapshot. |
| `src/container-driver.ts` | The container runtime: the computer as a Docker container, parked by freezing it. |
| `src/display.ts` | Display ports, the per-wake token, and the launch environment each display writes. |
| `src/network.ts` | Each guest's TAP device and /30, NAT and the network fence. |
| `src/agents.ts`, `src/registry.ts`, `src/agent-catalog.ts` | Agent tasks, the Agent Client Protocol registry, and agent install and sign-in. |
| `src/agent-routines.ts` | Persistent per-computer routines, same-UUID task recovery and bounded run history; [adapter contract and tests](../../docs/agent-routines.md). |
| `src/fs-proxy.ts`, `src/files.ts` | `/v1/fs`, `/v1/files` and the authenticated agent-app bridge, through the guest's file service. |
| `src/terminal.ts` | `/v1/terminal`: the terminal relay to the guest's terminal service, its control messages and session routes. |
| `src/screen.ts` | `/v1/screen/*`, the owner's display through its accessibility tree. |
| `src/app-catalog*.ts`, `src/craft-jobs.ts` | The optional application catalog and Craft CLI jobs. |
| `src/media.ts`, `src/phone.ts`, `src/desktop-notifications.ts` | Media handoff, iOS handoff, and desktop notifications from the guest. |
| `src/push.ts`, `src/apns.ts`, `src/activities.ts` | APNs push and Live Activities. |
| `src/guest-*.py` | Python run inside the guest: listing and launching apps, catalog operations, Craft jobs. |
| `scripts/` | Real-host checks, the Docker entrypoint and `setup-disks.sh`. |
| `systemd/caboose-host.service` | A user-service unit for running from a checkout. |
| `Dockerfile` | The self-hosting image (host, web console and Cloud Hypervisor). |

## Requirements

- Node 22 and pnpm.
- For the microVM runtime (the default): amd64 or arm64 Linux with `/dev/kvm`, a Cloud Hypervisor
  binary, and a guest image (`base.raw`, `vmlinux`, `initrd`), either built by
  [`guest/image`](../../guest/image/README.md) or fetched on first run from
  `CABOOSE_BASE_IMAGE` (see [Images](#images)). The disk root should be on XFS with reflink or
  on Btrfs; `scripts/setup-disks.sh` prepares one.
- On Apple Silicon macOS 14+, the microVM uses the signed AppKit Virtualization.framework
  helper, an arm64 guest image, and APFS for copy-on-write disks. The
  [macOS installer](../../deploy/macos/README.md) supplies the host, helper and menu app.
- For the container runtime: Docker and an image built from
  [`guest/container`](../../guest/container/README.md), or a registry image that the host
  pulls on first run.
- On Linux: root, or passwordless `sudo` for `ip`, `iptables` and `sysctl`. The host creates the TAP
  device `caboose0` (microVM) or the Docker network `caboose` with bridge `caboose-br0`
  (container), and installs its forwarding, NAT and fence rules.

The host serves plain HTTP and WebSocket. Put HTTPS/WSS in front of it with a trusted
reverse proxy before traffic crosses a network.

## Build and test

From the repository root:

```sh
pnpm install
pnpm --filter caboose-host typecheck
pnpm --filter caboose-host test
```

The unit tests cover the API, lifecycle, both runtimes with faked backends, agents, files,
catalog, push and the guest scripts. `scripts/display-client.test.mjs` replays the Caboose
Display Protocol vectors in `guest/display/vectors` through `scripts/display-client.mjs`, the
client the real-host checks use, so it encodes every canonical message byte for byte and
decodes it back. `src/fs-logic.test.ts` runs `guest/files/test_logic.py` and needs `python3`.

## Run

From a checkout, with the variables below in the environment:

```sh
pnpm --filter caboose-web build      # the console the host serves at /
pnpm --filter caboose-host start
```

Without `CABOOSE_OWNER_TOKEN`, the host generates an owner token on first start and keeps it
in `${CABOOSE_IMAGE_ROOT}/owner-token` (mode 0600). It logs that path; sign in to the console
with the token in that file.

`systemd/caboose-host.service` runs the same thing as a user service. Put the variables from
`.env.example` in `~/.config/caboose/host.env` (mode 0600), together with `CABOOSE_HOST_DIR`
(the absolute path of `apps/host`) and `CABOOSE_NODE` (the absolute path of the Node
executable). A user service needs a running user systemd manager, access to `/dev/kvm`, and
the non-interactive privileges above.

### Bundle

`scripts/bundle.sh <linux|darwin> <amd64|arm64> <outdir>` builds a self-contained host for
native installs, without Docker: `caboose-host-<os>-<arch>.tar.zst` on Linux and
`caboose-host-darwin-arm64.tar.gz` on macOS, plus a line in `<outdir>/SHA256SUMS`.
It needs pnpm, and zstd for Linux archives. macOS bundles build on Apple Silicon with
Xcode 16 command-line tools (Swift 6); installation needs neither Xcode nor Homebrew. The archive
holds one directory, `caboose-host/`:

| Path | What |
| --- | --- |
| `bin/caboose-host` | The launcher: the bundled Node runs `app/apps/host/dist/index.js`. It follows symlinks, so `/usr/local/bin/caboose-host` can point at it. |
| `bin/cloud-hypervisor` | Linux only: Cloud Hypervisor v54.0 (static, checked by SHA-256), used unless `CABOOSE_VMM_PATH` is set. |
| `bin/appkit-desk-vz`, `Caboose.app` | macOS only: the signed Virtualization.framework helper and menu bar application. |
| `bin/caboose-setup-disks` | `scripts/setup-disks.sh`, which prepares a reflink-capable disk root. |
| `node/` | Node v22.23.4 for the target, checked against nodejs.org's SHA-256. |
| `app/` | The compiled host with its production dependencies (`ws` and `appkit-desk`, plain JavaScript), the console, and the guest assets the host installs. |
| `defaults.env` | The release's pinned `CABOOSE_BASE_IMAGE` and `CABOOSE_CONTAINER_IMAGE`, used only when the environment does not set them. |
| `VERSION` | The release, from `CABOOSE_VERSION` or `git describe`. The launcher exports it as `CABOOSE_VERSION`, which `GET /v1/host` and the console report. |

The release workflow attaches the `linux-amd64`, `linux-arm64` and `darwin-arm64` bundles and
`SHA256SUMS` to each GitHub Release. `scripts/check-bundle.sh <bundle>` extracts one, starts it
through a symlink with an empty environment and a fresh state directory, and expects the
console, a generated owner token, one-time account setup, and an API that refuses requests without authentication.
`deploy/macos/check.sh <bundle>` checks installation and upgrade in an isolated home;
[`apps/macos/README.md`](../macos/README.md) describes the real guest check.

### Self-host with Docker

`deploy/compose.yaml` runs `apps/host/Dockerfile` with the microVM runtime. Use an amd64 or arm64
Linux machine with Docker and Compose, hardware virtualisation and `/dev/kvm`; Docker must
be able to run privileged containers. Build and start it from the checkout:

```sh
docker compose -f deploy/compose.yaml up -d --build
docker compose -f deploy/compose.yaml exec caboose-host cat /data/caboose/disks/owner-token
```

The image builds `caboose-host` and `caboose-web` from the workspace lockfile, serves the
console at `/` on the same port as the API, and pins Cloud Hypervisor to the matching architecture’s v54.0
static release (checked by SHA-256). Open `http://localhost:7310` on the server, or your
HTTPS proxy, and enter the owner token; the console keeps it in the tab's session storage.
To choose the token yourself, put `CABOOSE_OWNER_TOKEN` in `deploy/.env` (mode 0600); it is
supplied only at runtime, never during the build.

Once a release has been published (see [Images](#images)), `up -d` without `--build` pulls
`ghcr.io/braedonsaunders/caboose-host` (`CABOOSE_VERSION` picks the tag) instead of building.

State lives in `/data/caboose` on the host (`CABOOSE_STATE_DIR` in `deploy/.env` changes it)
and the computer's disks in `/data/caboose/disks` inside the container. When the state
directory is not on XFS or Btrfs, the entrypoint creates a sparse XFS image,
`disks.xfs.img`, with a 400 GiB maximum (`CABOOSE_DISK_SIZE`) that grows on use, and
loop-mounts it inside the container. Back up the whole state directory while the container
is stopped, and never run two containers against the same state directory.

The service publishes host loopback port 7310. Set `CABOOSE_PUBLISH_ADDRESS` in
`deploy/.env` to a specific address, or `0.0.0.0`, when a trusted reverse proxy or network
needs to reach it. HTTP carries the bearer token in cleartext. The container is privileged
for KVM, loop mounts and TAP networking; run it only on a trusted host. Its TAP, forwarding
and NAT rules live in the container's own network namespace.

The service starts and reports health before a guest image is installed, but cannot wake a
computer until `base.raw`, `vmlinux` and `initrd` are in its disk root. A release image
fetches them itself on first start. A checkout build has no `CABOOSE_BASE_IMAGE`; set it
to a published `caboose-base` reference, build them straight into the running container with `CABOOSE_HOST_CONTAINER` (see
[`guest/image`](../../guest/image/README.md)), or copy them in:

```sh
docker cp base.raw "$(docker compose -f deploy/compose.yaml ps -q caboose-host)":/data/caboose/disks/base.raw
```

To rotate the token, replace `CABOOSE_OWNER_TOKEN` in `deploy/.env` (or delete the generated
`owner-token` file) and run `docker compose -f deploy/compose.yaml up -d --force-recreate`;
every client needs the new token. Docker administrators can read the token from the
container's configuration or its state directory.

### Images

A release publishes three images to GHCR from `.github/workflows/release.yml` when a `v*`
tag is pushed:

| Image | What |
| --- | --- |
| `caboose-computer` | The computer as a container ([`guest/container`](../../guest/container/README.md)). |
| `caboose-base` | The microVM image as an OCI artifact with three layers titled `base.raw.zst` (zstd), `vmlinux` and `initrd`. |
| `caboose-host` | This host, built with `CABOOSE_BASE_IMAGE` and `CABOOSE_CONTAINER_IMAGE` set to the two images above, pinned by digest. |

When a microVM host starts without the three files in its disk root, it fetches them from
`CABOOSE_BASE_IMAGE`. It uses the registry's anonymous pull, checks every blob against its
digest as it streams, decompresses the disk, and writes it sparse. The manifest is checked
too when the reference is pinned by digest. A file that fails its check is deleted and
fetched again on the next wake; files that passed are kept. A container host whose Docker
lacks `CABOOSE_CONTAINER_IMAGE` pulls it when the reference names a registry.

While a download runs, a wake is refused with 409 and its progress, for example
"Downloading the computer's image (42%)", and `GET /v1/health` reports `image` (see
docs/architecture.md). A release pins its images, so a host never moves to a newer image
on its own, and a new base image reaches only new computers (see
[`guest/image`](../../guest/image/README.md)).

With no image in its disk root and no reference to fetch one from, a wake is refused with
409 and how to build it, and the console names the problem on Overview and Host.

Hosts, installers and Docker pull the three images anonymously, so they must be public;
packages a workflow pushes from this public repository are. The release workflow checks that
each image pulls anonymously before it attaches the bundles.

## Configuration

| Variable | Default | Meaning |
| --- | --- | --- |
| `CABOOSE_OWNER_TOKEN` | generated | A bearer token for every `/v1` request, beside accounts (the installers use it). Unset: generated once into `${CABOOSE_IMAGE_ROOT}/owner-token`. |
| `CABOOSE_DATABASE_URL` | unset | Postgres for accounts and tenants. Unset: an embedded PGlite database in `${CABOOSE_IMAGE_ROOT}/identity`. |
| `CABOOSE_AUTH_SECRET` | generated | Signs sessions; 32 characters or more. Unset: generated once into `${CABOOSE_IMAGE_ROOT}/auth-secret`. |
| `CABOOSE_BIND` | `127.0.0.1` | Listen address (`0.0.0.0` for every IPv4 interface). |
| `CABOOSE_PORT` | `7310` | Listen port. |
| `CABOOSE_IMAGE_ROOT` | `/var/lib/caboose` | Guest image, overlays, snapshots and the host's state files. |
| `CABOOSE_SPLIT_IMAGE` | unset | Directory containing a separately built split microVM image. New Linux computers bind to its immutable version; existing disks remain unchanged. Keep all four version files for those computers. |
| `CABOOSE_VM_DEPOT` | unset | Linux host directory for a shared Flatpak runtime depot, mounted read-only in microVMs using virtio-fs. Requires Docker, the computer container image, and virtiofsd 1.13 or later; cannot be combined with `CABOOSE_VM_COW=on`. |
| `CABOOSE_MEMORY_MB`, `CABOOSE_VCPUS` | `6144`, `4` | The owner's computer's size until saved settings exist, and a new computer's unless chosen. |
| `CABOOSE_IDLE_MS` | `600000` | Idle time before parking, likewise. |
| `CABOOSE_FREEZE_PARK_MS` | `60000` | Maximum frozen time before a microVM parks. |
| `CABOOSE_VM_COW` | `off` | `on` enables Cloud Hypervisor copy-on-write snapshot restore. |
| `CABOOSE_VM_FREE_PAGE_REPORTING` | `off` | `on` enables a zero-size virtio-balloon with free-page reporting on new Cloud Hypervisor boots. |
| `CABOOSE_SNAPSHOT_TIER` | `off` | `on` archives parked Linux microVM memory to the configured private S3-compatible store after four hours. |
| `CABOOSE_SNAPSHOT_KEY_FILE` | unset | Absolute path to a host-owned mode 0600 file containing a 32-byte encryption key as lowercase hex. Required when tiering is on. |
| `APPKIT_STORAGE_ENDPOINT`, `APPKIT_STORAGE_BUCKET`, `APPKIT_STORAGE_ACCESS_KEY_ID`, `APPKIT_STORAGE_SECRET_ACCESS_KEY` | unset | S3-compatible storage connection used for cold snapshots. Required when tiering is on. |
| `CABOOSE_MAX_RUNNING` | `4` | microVM computers that may run at once; waking another waits for one to park. |
| `CABOOSE_PUBLIC_URL` | unset | Where phones reach this host from anywhere, such as `https://caboose.example.com`; listed first in pairing links and used as the console auth base URL (auth defaults to loopback when unset). |
| `CABOOSE_MDNS` | `on` | `off` stops advertising `_caboose._tcp` on the LAN. |
| `CABOOSE_VMM_PATH` | `/usr/local/bin/cloud-hypervisor` | Cloud Hypervisor (microVM). |
| `CABOOSE_RUNTIME` | `microvm` | `microvm` or `container`. |
| `CABOOSE_BASE_IMAGE` | empty (release: pinned) | OCI reference fetched when the disk root lacks the image (microVM). |
| `CABOOSE_CONTAINER_IMAGE` | `caboose-computer:latest` (release: pinned) | The computers' image (container); pulled when missing if it names a registry. |
| `CABOOSE_CONTAINER_NAME` | `caboose-owner` | The owner's computer's container name; others are `caboose-<id>` (container). |
| `CABOOSE_CONTAINER_HOME` | `caboose-home` | Volume name or absolute host path for the owner's `/home/caboose`; others append `-<id>` (container). |
| `CABOOSE_CONTAINER_ARGS` | empty | Extra `docker run` arguments, whitespace-separated (container). |
| `CABOOSE_GPU` | `auto` | `wsl`, `nvidia`, `dri` or `none`; `auto` detects `/dev/dxg`, then NVIDIA, then `/dev/dri/renderD128` (container). |
| `CABOOSE_GUEST_LAN` | `deny` | `allow` lets the computer reach private networks. |
| `CABOOSE_WEB_ROOT` | `apps/web/dist` | The built console. Do not point it at a source or data directory. |
| `CABOOSE_AGENT_REGISTRY_URL` | the public ACP registry | An http(s) URL of a registry mirror. |
| `CABOOSE_AGENT_IDLE_MS` | `600000` | How long an agent stays running after a turn, waiting for a reply. |
| `CABOOSE_APNS_KEY_PATH`, `CABOOSE_APNS_KEY_ID`, `CABOOSE_APNS_TEAM_ID`, `CABOOSE_APNS_TOPIC` | unset | APNs; all four together. |

Invalid values stop the host at startup. `GET /v1/host` reports the version, runtime, GPU,
image and the non-secret settings the host started with.

Run `pnpm --filter caboose-host exec tsx scripts/check-snapshot-tier.mts` on a
Linux host with the tier and storage variables set to check an encrypted
upload, restore and object cleanup using a disposable snapshot. The check
retains local receipts and reports their path if cleanup fails.

Copy-on-write restore cannot be combined with virtio-fs shares, including shares
recorded in a parked snapshot. Cloud Hypervisor v54 writes complete snapshots; it does
not provide dirty-page-only snapshot deltas. Free-page reporting requires the guest balloon driver.

Cold snapshot storage also accepts `APPKIT_STORAGE_REGION` and
`APPKIT_STORAGE_FORCE_PATH_STYLE` (`true` or `false`). Back up the snapshot key
with the computer disks and host state: without it cold memory cannot be
restored. Store the key separately from the object bucket. If tiering is turned
off while a cold snapshot exists, wake, restart and deletion refuse until the
storage and original key are configured again. Cold restore needs enough local
space for the restored snapshot. Failed object deletion is retried using local
cleanup receipts, including receipts for deleted computers. An image root is local to one host; receipts from a different hostname are retained for operator review. A source file left by a crashed copy-on-write VM must be kept
until an operator has confirmed no VMM maps it.

The owner's computer's name, memory, CPUs, idle timeout and default agent are saved in
`caboose.json` under `CABOOSE_IMAGE_ROOT` (atomic rename, mode 0600); saved values override
the environment. Invalid or unreadable settings stop startup rather than reverting. Back the
file up with the disks and do not edit it while the host runs. Its push devices
(`push-devices.json`) and Live Activities (`activities.json`) live beside it, with the agent
registry cache (`agent-registry.json`), the computer registry and people in the identity database, and phone
sign-ins (`phones.json`, SHA-256 digests only). Every other computer keeps its own
`caboose.json`, `push-devices.json` and `activities.json` in `computers/<id>/`.

## Accounts and tenants

The console accepts the same account through its LAN HTTP address and its HTTPS proxy.
Session cookies match that connection; an HTTPS `CABOOSE_PUBLIC_URL` does not force
HTTPS-only cookies onto a LAN HTTP sign-in. HTTPS sessions retain Secure cookies.

Administrators sign in to the console with an email and password; the people whose computers
they run use only their phones and need no account. A tenant is a household or a team, with
its computers, its administrators and quotas on memory, vCPUs and disk. The first account is
the operator's, who sees every tenant and the host itself.

A new host is unclaimed: it writes a one-time code to `${CABOOSE_IMAGE_ROOT}/setup-code` and
logs `Set up Caboose: http://<address>:<port>/setup?code=<code>`. `/setup` opens with that
code, including on the host itself: a local proxy may relay outside traffic without
forwarding headers. It makes the operator's account and the first tenant, gives it the
host’s computers, and deletes the file. The owner computer is assigned to the operator’s
person record in the same database transaction. The owner-token console offers Complete
setup until this is done; existing computers and paired phones continue to work. Other administrators join by invitation links
from **People**. Accounts and sessions are AppKit's (`appkit-auth`, `appkit-db`) in the
embedded database, or Postgres with `CABOOSE_DATABASE_URL`. Back up `identity/` (or the
Postgres database) with the disks. The owner token keeps working for the whole API.

## Computers

Computers belong to people, and people belong to tenants. The identity database stores
both in `caboose_computers` and `caboose_people`, enforcing tenant/person foreign keys.
New computers require a selected person. Deleting a person with computers is refused.
The first startup imports the legacy JSON registry atomically without changing disk ids,
network slots or phone tokens; the original file remains a backup. Unknown legacy owners
remain marked Assignment required. Back up the database with the disks.


The owner token manages every computer through `/v1/computers` (list, make, delete) and
reaches any one under `/v1/computers/<id>/…`; the routes without an id serve the owner's
computer, as they always have. Each computer has its own disk, settings, lifecycle, agents,
catalog, notifications and phones, and its own network slot: a microVM on slot *n* gets TAP
`caboose<n>` and a persistent /30: slots 0–63 use `192.0.2.0/24`, later slots use
`198.18.0.0/15`. A container has its own home and bridge; slots 1–63 retain loopback ports
from 20000 + 10 × *n*, and later slots use available loopback ports outside that range; stopped containers retain their allocations. The owner's computer is slot 0 with the names and
addresses below, and cannot be deleted. Deleting another computer removes its disk, files,
network and phones.

Phones sign in to one computer each. The console's **Sign in a phone** asks for a pairing
code (`POST /v1/computers/<id>/pairing`), shown as a QR code; the app trades it once, within
ten minutes, for its own token through `POST /v1/pair`. A phone token reaches only its own
computer's routes and is signed out from the console. The owner token still works on a
phone, as it did before.

## Runtimes

**microVM** (default). The computer is a Cloud Hypervisor microVM managed by appkit-desk.
Its disk is a reflink copy-on-write overlay of `base.raw` (`overlays/<id>.raw`, `owner.raw`
for the owner's); parking writes a memory snapshot (`overlays/<id>.snapshot`), so a parked
computer survives a host restart. Commands run in the guest over vsock through the guest
agent. The owner's guest has address `192.0.2.2` on the TAP device `caboose0`.

**Container** (`CABOOSE_RUNTIME=container`). For a GPU a container can use but a VM cannot:
WSL2's `/dev/dxg`, an NVIDIA GPU through the NVIDIA container toolkit, or Linux render nodes.
The host runs the image on its own Docker network with public DNS, publishes the displays
(14600, 14601), the file service (14700) and the terminal service (14701) on loopback only, mounts the home volume, passes
the GPU (`/dev/udmabuf` too, when the host has it), and drives the computer with
`docker exec` and the image's `caboose-session start | ready | start-agent | start-files`.
Parking freezes the container (`docker pause`): memory stays in RAM and waking is immediate,
but a Docker or host restart loses the running session and the next wake starts fresh with
the home intact. A cold restart stops and starts the same container, so installed packages
survive; removing the container discards them. New containers get Caboose's seccomp profile
(`guest/container/caboose-seccomp.json`) unless `CABOOSE_CONTAINER_ARGS` sets one, and mount the
shared runtime volume `caboose-depot` read-only.

A computer is fenced in both runtimes: it can open no connection to the host or to another
computer, and reaches only the public internet, not private, link-local (cloud metadata),
CGNAT or Tailscale addresses. `CABOOSE_GUEST_LAN=allow` lets a self-hosted computer reach
your LAN, never another computer.

## Displays

The host writes a random token to `/run/caboose/display-token` in the guest (mode 0600,
owner `caboose`): the microVM gets a new one at every wake, a container when it is created,
restarted, or first woken by a newly started host. An interactive wake starts the
file service and the owner's display
(`caboose-display.service` in the microVM, `caboose-session start` and `ready` in a
container) and waits until it answers a hello carrying the token and has written its
launch environment (`caboose-display-ready`). It then reads the launch environment the display wrote to
`/run/caboose/display.env` (its Wayland socket, Xwayland's `DISPLAY` and `XAUTHORITY`,
toolkit hints, `PULSE_SERVER`); apps, sign-in windows, opened files and the screen routes are
started with it.

Agent tasks and routines can wake headlessly: components and file service start, while the
owner display starts on an interactive session, display connection or app launch. The agent
display starts on a desktop tool call or an agent-seat display connection. A restored memory
snapshot keeps any displays that were already running.

When AppKit supports resident pause, a microVM with no leases freezes after three seconds;
new work resumes it. It parks at the earlier of its idle timeout or the host's
`CABOOSE_FREEZE_PARK_MS` after freezing. Container and unsupported microVM backends park at
the configured idle timeout.

On a disposable Linux microVM host with resident pause support, run
`CABOOSE_OWNER_TOKEN=… node apps/host/scripts/check-freeze.mjs` to check freeze, resume,
park and snapshot restore. Set `CABOOSE_URL` for a nonlocal host and
`CABOOSE_CHECK_TIMEOUT_MS` if the configured timeouts exceed 90 seconds. Close other clients
and terminal sessions first; the check wakes the computer and leaves it running.

`POST /v1/session` returns `{ state, display: { path: "/v1/display", token, protocol:
"caboose-display" }, computer }`. `/v1/display` is a WebSocket (subprotocol `binary`) that
relays bytes to the owner's display on guest port 14600; `/v1/display?seat=agent` relays to
the agent seat on port 14601, starting `caboose-display-agent.service` (or
`caboose-session start-agent`) first if it is not running. The host does not parse the
stream. Every open WebSocket holds a lease that keeps the computer awake.

## Computer management

The web console and the iOS app use `GET /v1/computer`, `PATCH /v1/computer/settings` and
`POST /v1/computer/restart`. Status never wakes or leases the computer. Name and idle
timeout changes apply immediately. CPU and memory changes apply on a cold restart; resuming
a memory snapshot keeps its previous resources. The response reports `activeResources` and
`restartRequired`, also while parked; the microVM records applied resources in
`overlays/<id>.resources.json`.

Restart requires `{ "confirm": true }`. It closes client connections, ends agent tasks,
discards open application memory and boots the existing disk; it does not restart the Linux
host or delete the disk. The response waits for the display to be ready; allow 300 seconds.
Concurrent restarts return 409. The host attempts a short disk flush first; an unresponsive
guest is restarted anyway and the failure is kept in `lastError`, and, as after a power
loss, unsaved writes can be lost. Park instead keeps application memory.

The host serves the built console at `/`. Static assets and console routes are public; every
`/v1` request but `POST /v1/pair` needs the owner token or a phone token. Missing assets
return 404.

## Agents, files and the screen

Agents (`/v1/agents`), agent tasks (`/v1/agent/tasks`), replies, approvals, attachments,
`POST /v1/files` and `POST /v1/open` are specified in `docs/architecture.md` § Agents. Agents
come from the Agent Client Protocol registry and run in the computer through
[`caboose-agentd`](../../guest/agentd/README.md); the host has no code for any particular
agent. A task starts the agent seat if needed and runs as `caboose` with the seat's launch environment
(`/run/caboose/agent-display.env`, Xwayland `:101`) and the seat's D-Bus session bus
`/run/user/1000/agent-bus`. New tasks offer installed catalog MCP commands to the agent;
`craftMcp: false` in `POST /v1/agent/tasks` turns them off for that task and its replies.
The list is captured when the task is created. Replies and their staged files are admitted
into a durable per-task guest journal before success is returned. `AgentTasks.start(input,
{ id })` accepts a stable UUID; reply `operationId` values deduplicate retries per task and
conflict on changed original payloads. Recovery and uncertain-delivery behavior are specified
in the architecture and runner file protocol linked above. Focused tests:

```sh
pnpm --filter caboose-host exec vitest run src/agents.test.ts src/agent-delivery.test.ts
pnpm --filter caboose-agentd test
```

`/v1/fs` and shared files go through the guest's file service
([`guest/files`](../../guest/files/README.md), port 14700, authenticated with the per-wake
token). Streaming requests wake the computer and hold a lease until the transfer finishes.
Client disconnects cancel the relay; 60 seconds without transfer progress ends it with 504
before response headers, or closes an incomplete response. Active transfers have no total
duration limit.
The route, precondition, Trash and change-feed contract is in `docs/architecture.md` § Files.

`/v1/terminal` ([`src/terminal.ts`](src/terminal.ts), `docs/architecture.md` § Terminal) is a
WebSocket per terminal, relayed to the guest's terminal service
([`guest/terminal`](../../guest/terminal/README.md), port 14701, authenticated with the
per-wake token). It wakes the computer only with `wake=1`, holds a lease while open, allows 8
per client (the owner, or each phone), closes after 15 minutes with nothing either way,
pauses each side until the other has flushed, and checks every JSON control message in both
directions. Sessions outlive their connection; `GET /v1/terminal/sessions` lists them and
`DELETE /v1/terminal/sessions/:id` hangs one up. A container created before the terminal
existed has no port for it, so the host reaches the service on the container's bridge
address.

`/v1/screen/elements`, `act`, `type` and `keys` (`src/screen.ts`, `docs/architecture.md`
§ Screen) read and drive the owner's display, Wayland and X11 applications alike. They run
`/opt/caboose/a11y.py` and `/opt/caboose/seat.py`
([`guest/desktop-mcp`](../../guest/desktop-mcp/README.md)) as `caboose` with the owner
display's launch environment, which names its control socket.

## Media handoff

`src/media.ts` reads the video playing in the computer's Chromium from
`/home/caboose/.cache/caboose/media.json` (written by
[`guest/media-handoff`](../../guest/media-handoff/README.md)) about once a second, only
while the computer is running and a display client is connected, and broadcasts
`media.playing` and `media.stopped` on `/v1/control`. `GET /v1/media` returns the current
state (null unless running; it never wakes or leases the computer).
`POST /v1/media/:id/control` with `{ "action": "pause" }` or
`{ "action": "play", "position": 42.5 }` writes a command for the guest as `caboose` and
returns `{ "sent": true }`, or 409 while the computer is not running. The contract is in
`docs/architecture.md` § Media handoff.

## Notifications and Live Activities

Desktop notifications from the owner's session (see
[`guest/notifications`](../../guest/notifications/README.md)) are drained from the guest
while it runs and sent as `notification` events and, with APNs configured, as pushes.

Set all four `CABOOSE_APNS_*` variables (the key is a private P-256 `.p8` file) to enable
APNs. Devices are stored in `push-devices.json` and Live Activity registrations in
`activities.json`, both under `CABOOSE_IMAGE_ROOT` with mode 0600. Agent task events update
Live Activities; other producers can publish the generic job shape through
`POST /v1/jobs/activity`. The sender uses the app topic with `.push-type.liveactivity`
appended. The API and its limits are in `docs/architecture.md` § Notifications.

## MCP Library

`src/smithery.ts` is the catalog (Smithery's registry, cached in `CABOOSE_IMAGE_ROOT/smithery`),
`src/mcp-library.ts` a computer's Library (its Smithery account, connections and the computer's
access token, in the computer's `mcp-library.json`), and `src/safe-fetch.ts` the client for hosts
named by untrusted metadata. Routes are under `/v1/mcp` (`docs/architecture.md` § MCP Library and
§ HTTP API). Tests use a stand-in Smithery; nothing in them reaches the network.

## Catalog and Craft jobs

The Library is the curated catalog in [`guest/catalog`](../../guest/catalog/README.md) followed
by Flathub (`docs/architecture.md` § Catalog). `GET /v1/catalog` lists curated entries and every
installed application; `GET /v1/catalog/discover?q=&category=&offset=` ranks the whole Library 40
at a time without a running computer. `src/flathub.ts` keeps Flathub's index and icons in
`CABOOSE_IMAGE_ROOT/flathub`, `src/releases.ts` the latest verified Craft releases in
`CABOOSE_IMAGE_ROOT/releases`, and `src/depot.ts` the shared runtime depot's record in
`CABOOSE_IMAGE_ROOT/depot.json` (`docs/architecture.md` § Runtime depot). On the container
runtime the depot is the Docker volume `caboose-depot` and its builder runs `src/depot-builder.py`
in a throwaway container from `CABOOSE_CONTAINER_IMAGE`. Linux microVM hosts can set
`CABOOSE_VM_DEPOT` to share a host directory read-only via virtio-fs; otherwise each
computer installs its own runtimes. A snapshot taken before the share was enabled uses
its local runtimes until a cold restart attaches the share. Virtio-fs requires shared guest memory; Cloud
Hypervisor restores shared memory eagerly, so the host rejects enabling both the depot and
`CABOOSE_VM_COW=on`.

Install, update and removal are asynchronous; watch `catalog.progress` and `catalog.changed` on
`/v1/control`. Installed applications update once a day while their computer runs. The guest
downloads and verifies Craft releases against their published SHA-256 before APT runs, Debian
packages come from the signed Debian 13 repositories, Flathub apps install through
libflatpak, and catalog games are checked against their pins and unpacked as `caboose` into
`~/.local/share/caboose/games` ([docs/game-handoff.md](../../docs/game-handoff.md#catalog-games)).
Progress percentages describe measured download bytes only; verification, package
installation and triggers show indeterminate stages. One catalog operation runs at a time.
Listings distinguish a lock-held active operation from an interrupted worker; the host observes
surviving work and holds its lease until it ends. Retry completes pending dpkg configuration
even if the application already reports an installed version.

`apps/host/scripts/check-flathub.sh` checks the depot builder, a read-only depot mount, a
Flathub install that uses the depot's runtime, a sandboxed run under Caboose's seccomp profile
and removal, in disposable Debian containers; it needs Docker and about 1 GB from Flathub.
`apps/host/scripts/check-store.sh` checks that a Debian app installed through the earlier
AppStream discovery is rediscovered from its record.

Craft jobs run a fixed list of installed catalog CLI operations, as `caboose`, on files
staged in `~/.caboose-jobs/<job>` through `/v1/fs`. The contract, formats, progress events
and retention are in `docs/architecture.md` § Shortcuts and Spotlight.

## iOS handoff

The host relays validated guest `phone.open`, `phone.share` and `phone.print` events only to
owner-authenticated `/v1/control?phone=1` sockets, and polls the guest only while one is
connected. `GET /v1/phone/files/:id` reads a staged file through the guest command channel;
it accepts no arbitrary guest path and never wakes the computer. The schema and delivery
rules are in `docs/architecture.md` § Phone handoff; the guest side is
[`guest/phone`](../../guest/phone/README.md).

## Guest components

After each wake the host compares the guest components it bundles (`guest/components`) with
the version marker in the computer, and installs them when they differ. Progress and
failures appear as `upgrade` in `GET /v1/computer` and as `computer.upgrade` events; a
failure is retried on the next wake. A container created without the port 14700 mapping must
be recreated to enable Files; keep its home volume. `guest/components/README.md` has the
disposable-guest check, and `check-upgrade.mjs` (below) the real-host one.

App launches log `App launch timing` with the initial lifecycle state, last phase,
`acknowledged` or `failed`, and milliseconds for queued wake, preparation and total.
Subtract wake and preparation from total to measure dispatch. These records omit
app IDs, arguments, tokens and guest error text. They measure dispatch, not first window
appearance. A request timeout on the phone does not cancel work already admitted by the host.

## Real-host checks

These run against a deployed host with a built guest, are separate from the unit tests, and
change the computer as described. Except for `check-push.mjs`, each reads
`CABOOSE_OWNER_TOKEN` and `CABOOSE_URL` from the environment; keep the token in your private
environment, not in shell history. `check-fs.mjs`, `check-terminal.mjs`, `check-craft.mjs` and
`check-open-app.sh` require `CABOOSE_URL`; the others default to `http://127.0.0.1:7310`. Run them from the repository root with Node 22.

| Command | What it checks |
| --- | --- |
| `CABOOSE_OWNER_TOKEN=… apps/host/scripts/e2e.sh` | Wakes the computer (cold only without a snapshot), says an authenticated hello to the owner's display and the agent seat through the relay with `scripts/display-client.mjs` and requires an encoder it decodes, checks the app list has PNG icons and the core apps, launches the Xfce terminal, parks, resumes, says hello again, checks `/v1/health` has no desk error, and parks. |
| `node apps/host/scripts/check-lineup.mjs` | Opens Mousepad, btop and OpenCode and requires a new window for each on the owner's display. Leaves them open and does not park. |
| `node apps/host/scripts/check-catalog.mjs` | Installs PhotoCraft (or the catalog app `CABOOSE_CATALOG_APP` names, such as `powder-toy`) if needed, launches it and requires a new window with its name and a PNG icon in the app list. Close the app's windows first. |
| `node apps/host/scripts/check-management.mjs [--write \| --restart]` | The management API: read-only by default; `--write` saves the existing name unchanged; `--restart` performs a cold restart (discarding open applications) and checks the applied resources. |
| `apps/host/node_modules/.bin/tsx apps/host/scripts/check-container-ports.mts` | Real Docker port allocation, including legacy and stopped container bindings; requires an existing `node:22-bookworm-slim` image (override with `CABOOSE_CHECK_IMAGE`). |
| `node apps/host/scripts/check-computers.mjs [--fence]` | Several computers: makes a throwaway computer, wakes it, pairs a phone with it through a pairing code and checks the phone reaches only that computer, signs it out, then deletes the computer and its disk. Hosts with accounts also get a throwaway tenant, removed after the computer even when the check fails. Older hosts without tenants remain supported. It creates no accounts; the owner's computer is only read. `--fence` also checks the rule that rejects traffic between computers (root or `sudo -n`). |
| `node apps/host/scripts/check-accounts.mjs` | Accounts and tenants: the setup state and the owner token's view, then a throwaway tenant with a memory quota, a computer within it made and one beyond it refused, a resize past it refused, and both deleted. It makes no accounts and verifies that setup requires its code even on loopback. |
| `node apps/host/scripts/check-upgrade.mjs` | Wakes the computer, waits for the guest component update to finish, and exercises Files. |
| `node apps/host/scripts/check-terminal.mjs` | Opens a terminal through `/v1/terminal` (waking the computer), checks the login shell's environment, resizes, lists the session, detaches, reattaches from its offset and receives what was written meanwhile, then exits the shell with a code. A failed check hangs the session up. |
| `node apps/host/scripts/check-fs.mjs` | Creates a temporary directory, uploads, lists, downloads a byte range, moves, and trashes its files and the directory. |
| `node apps/host/scripts/check-agents.mjs [--agent <id>] [--install] [--open]` | Saves a file to `~/Downloads`, lists the registry, and runs a real task with the given agent (default: the computer's default agent) that asks before acting with an attachment, approves it through the API, and replies. The agent must be signed in; `--install` installs it first; `--open` also opens https://example.com on the owner's display. |
| `node apps/host/scripts/check-craft.mjs <app> <files…>` | Runs a Craft job (`photocraft`, `pdfcraft`, `lightcraft`, `filmcraft`) on the given files, checks the output signature and moves the job directory to Trash. FilmCraft media must already be on the computer at the paths in the project. Failed jobs remain for inspection. |
| `apps/host/scripts/check-open-app.sh` | With `CABOOSE_CHECK_FILE` (a local document) and `CABOOSE_CHECK_APP` (an installed desktop entry id): uploads the file and opens it with that app. Check the owner's display; the test copy stays in a uniquely named folder in the home. |
| `node apps/host/scripts/check-push.mjs [device-index]` | Run on the host with its `CABOOSE_APNS_*` variables and `CABOOSE_IMAGE_ROOT`: sends a test alert to a device from `push-devices.json` (default index 0) without printing tokens. APNs acceptance is not proof of delivery; check the device. |
| `apps/host/scripts/check-container.sh` | Against the running Compose service on Linux: the container's own network namespace, TAP and NAT, KVM access, the reflink disk root, authenticated health, and the bundled console (HTML, compiled assets, SPA fallback, API authentication). |

`apps/host/scripts/check-agent-shell.sh` needs only Docker (and network for its image build):
it runs the host's agent and file guest scripts (task start, the batched poll, replies,
approvals, cancel, restore after a host restart, sign-in, attachments and Downloads) in a
Debian 13 container where the real `caboose-agentd`, installed by its own `install.sh`,
drives a stand-in ACP agent.

`guest/desktop-mcp/check-a11y.sh` covers the accessibility helper behind the screen routes,
`guest/media-handoff/check.sh` the media handoff guest, `guest/files/check-service.py` the
file service, and `guest/terminal/check-service.py` the terminal service; see their READMEs.

Agent profiles are private per-computer records in `agent-profiles.json`, with identity,
provider, instructions, approval default and owner-editable memories. Profile APIs remain
available while the computer is parked. Tasks select `profileId`; new conversations receive
its current context snapshot and share `~/AgentWorkspaces/<profile UUID>`. Existing
conversations retain their snapshot. Archiving a profile prevents new starts and preserves
its workspace. See the architecture contract for endpoints and limits.

Agent model discovery uses `POST /v1/agents/:id/models`, backed by an ACP session with
no prompts or MCP servers. Task creation accepts an advertised `model` id. Read a chat's
requested and confirmed selection with `GET /v1/agent/tasks/:id/models`; `PUT` with
`{ "model": "<advertised id>" }` selects the next-message model while the chat and queue
are idle. Providers without an advertisement omit `models`. The runner checks the id
against fresh session options before prompting; the host does not infer models from keys
or environment variables. See `guest/agentd/README.md` for persistence and ACP negotiation.

### Desktop shortcut endpoint

`POST /v1/apps/:id/desktop-shortcut` creates an owner-owned standard `.desktop` shortcut in
`~/Desktop` from a visible installed application. It returns `{ path }` with status 201,
404 for an unavailable app, and 409 for a filename collision. Entries are bounded to 256 KiB,
the Desktop directory cannot be a symlink, and publication never overwrites an existing item.
The copy includes `X-Caboose-AppId` for the native app's installed-ID launch route.
Run `pnpm test -- src/guest-apps.test.ts` for copy, collision, traversal and symlink checks.

Computer creation and settings accept the `micro`, `standard`, and `gpu` size presets;
see [the architecture](../../docs/architecture.md) for resources and GPU availability.
Custom CPU and memory settings remain available.

Chat deletion is covered by `pnpm --filter caboose-host exec vitest run src/agents.test.ts src/agent-delete.test.ts src/server.test.ts src/fleet.test.ts`
from the repository root. On a real Linux computer, create a chat that writes a file in
its working directory and one outside it, then swipe Delete in Agents > Chats. Confirm
Stop and Delete while running (repeat while paused and while awaiting approval). Verify
both generated files remain, the runner group exits, and the chat stays absent after a
host restart. A concurrent reply must either finish before deletion or fail without
recreating history. If runner identity cannot be verified, deletion fails visibly.

The runner-group deletion check uses a disposable Linux Node container with no network,
128 MiB memory and one CPU. It creates its own detached runner wrappers, exercises
running and paused deletion, verifies generated files and tombstones, and rejects an
unrelated process group. From the repository root (with the Node image already present):

```sh
pnpm --filter caboose-host exec tsx -e "import {writeFileSync} from 'node:fs'; import {DELETE_TASK} from './src/agents.ts'; writeFileSync('/tmp/caboose-delete-task-code.js', DELETE_TASK)"
docker run --rm --init --network none --memory 128m --cpus 1 -v "$PWD/apps/host/scripts/check-agent-delete.mjs:/check.mjs:ro" -v /tmp/caboose-delete-task-code.js:/delete-task.js:ro node:22-bookworm-slim node /check.mjs /delete-task.js
rm /tmp/caboose-delete-task-code.js
```
