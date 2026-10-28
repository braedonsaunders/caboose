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

## Agents and files

Agents (`/v1/agents`, install and sign-in), agent tasks (`/v1/agent/tasks`), replies,
approvals, attachments, `POST /v1/files` and `POST /v1/open` are specified in
`../../docs/architecture.md` § Agents. Agents come from the Agent Client Protocol registry
(`src/registry.ts`; `CABOOSE_AGENT_REGISTRY_URL` selects a mirror), cached in
`${CABOOSE_IMAGE_ROOT}/agent-registry.json`, and run in the computer by `caboose-agentd`
(`guest/agentd`); the host has no code for any particular agent. `CABOOSE_AGENT_IDLE_MS`
sets how long an agent stays running after a turn, waiting for a reply. The host talks to
the guest only through the driver's `guest().run(command, args)`; file contents are sent
as base64 argument chunks and decoded in the guest, so both the microVM and container
drivers support them without a stdin channel.

The owner-screen routes (`/v1/screen/*`, § Screen) are in `src/screen.ts`: they run the
guest's accessibility helper `/opt/caboose/a11y.py` (see `guest/desktop-mcp`) and `xdotool`
as `caboose` on `:100`. `guest/desktop-mcp/check-a11y.sh` runs that helper in real Xvfb and
Xpra sessions under Docker.

The guest scripts behind these routes (task start, the batched poll, replies, approval
decisions, cancel, restore after a host restart, sign-in, attachments and Downloads) run
for real in a Debian 13 container, where the real `caboose-agentd`, installed by its own
`install.sh`, drives a stand-in ACP agent: the same session continuing, a new runner
reloading a session or recapping it, a signed-out agent signed in through
`authenticate`. This needs only Docker (and network for the image build):

```sh
apps/host/scripts/check-agent-shell.sh
```

Against a real host, the agent check saves a file to `~/Downloads`, lists the registry,
and runs a task with the given agent (default: the computer's default agent) that asks
before acting with an attachment, approves it through the API, and replies. The agent must
be signed in; `--install` installs it first. `--open` also opens https://example.com on
the owner's display. It starts real agent runs on the owner's account.

```sh
export CABOOSE_URL=https://computer.example.com
# Supply CABOOSE_OWNER_TOKEN through your private environment.
node apps/host/scripts/check-agents.mjs [--agent <registry id>] [--install] [--open]
```

## Media handoff

`src/media.ts` reads the video playing in the computer's Chromium from the guest's
`/home/caboose/.cache/caboose/media.json` (written by `guest/media-handoff`) about once a
second, only while the computer is already running and a display client is connected,
and broadcasts `media.playing` / `media.stopped` on the control socket. `GET /v1/media`
returns the current state (null unless running; it never wakes or leases the computer).
`POST /v1/media/:id/control` with `{ "action": "pause" }` or
`{ "action": "play", "position": 42.5 }` writes a command for the guest as user `caboose`
and returns `{ "sent": true }`, or 409 while the computer is not running. The contract is
in `../../docs/architecture.md` § Media handoff. Unit tests fake the guest; check a real
guest with `guest/media-handoff/check.sh`, then play a video in Chromium and watch
`GET /v1/media` while the app is connected.

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

`CABOOSE_DISPLAY` picks the owner's display server. `xpra` (the default) runs Xpra
on display `:100` and relays guest port 14500. `caboose` runs caboose-display instead
(docs/display.md): the microVM's `caboose-display.service`, ready once
`caboose-display-ready 60` has a hello answered, or `caboose-session start-display` and
`ready-display` in a container. The relay then targets guest port 14600, `/v1/session`
returns `protocol: "caboose-display"`, and apps launch with the environment
caboose-display writes to `/run/caboose/display.env` (its Wayland socket, Xwayland's display
and cookie, toolkit hints), read at every wake. The agent seat stays Xpra `:101` either
way. The image must include caboose-display.

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

## Application catalog

The pinned catalog in `guest/catalog` is served at `GET /v1/catalog`. Install, update,
rollback and removal are asynchronous; watch `catalog.progress` and `catalog.changed`
on `/v1/control`. The guest downloads and verifies release packages before APT runs.
Only one catalog operation runs at a time. An interrupted operation is reported by the
next catalog listing; inspect its error and retry. Debian package installs use the signed
Debian 13 repositories. Rollback is available only when an earlier release package was
cached. The container runtime retains its writable layer across a Caboose cold restart.

With an Xpra owner display and a deployed computer, verify PhotoCraft's guest download,
installation, launch and software rendering (close any existing PhotoCraft window first):

```sh
export CABOOSE_URL=https://computer.example.com
# Supply CABOOSE_OWNER_TOKEN in the private environment. Requires a local Xpra client.
node apps/host/scripts/check-catalog.mjs
```

The check wakes the computer, installs PhotoCraft if needed, and leaves the window open.
It requires a new Xpra window and is separate from the host unit tests.

## iOS handoff

The host relays validated guest `phone.open`, `phone.share`, and `phone.print` events
only to owner-authenticated `/v1/control?phone=1` sockets, and only polls while one is
connected. `GET /v1/phone/files/:id` reads a staged file through the guest command
channel; it does not accept arbitrary guest paths or wake the computer. See
`../../docs/architecture.md` § iOS weave for the schema, limits and delivery semantics,
and `../../guest/phone/README.md` for the guest-side CUPS and command check.
