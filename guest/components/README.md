# Guest components

The manifest lists the exact files shipped by the host. `version.py` and the host hash the
ordered file names and bytes identically. `install.sh` installs missing dependencies,
updates system-owned files (including the agent runner and its pinned npm dependencies), configures services and writes the version marker only after
success. It never modifies the owner's home. Both image builders call it in image mode;
the host calls it through root guest exec in `vm` or `container` mode after wake, including
headless wakes.
The installer provides AppStream and its Python introspection bindings, which rediscover Debian apps installed through the Library's earlier AppStream search, and Flatpak with its introspection bindings for Flathub apps ([`guest/flatpak`](../flatpak/README.md)). It also provides GTK 3's introspection data for `caboose-game-run` ([guest/game](../game/README.md)). It refreshes APT metadata after adding AppStream.
The installer preserves working `node` and `npm` commands, including npm bundled with
NodeSource's `nodejs`. It installs Node when unusable, then checks npm again before
requesting Debian's separate `npm` package. Both commands must run before system files
are updated. The installer is safe to repeat. The Thunar action is a system default: user
custom actions can override it. See `docs/architecture.md` § Guest for the API and
older-container caveat.

From the repository root, `python3 guest/components/test_install.py` checks dependency
detection and APT failures with isolated shell fixtures. It needs Bash and Python 3, runs
without root, Docker or network access, and stops before the first system-file write.

`python3 guest/components/test_staging.py` checks that every file in `manifest.json` is
staged where each builder runs the installer: the host image's `/app/guest` (for updating
computers), the container image's `/tmp/bundle`, and the VM image's `/builder` directories
that `guest/image/build-inside.sh` moves to `/tmp` and removes afterwards. Add a component's
files to all three when you add them to the manifest.

`pnpm install` then `guest/components/check-container.sh` starts
a disposable Debian guest without components, upgrades it over the same exec transport,
checks services (including terminal authentication and ownership), the runnable agent runner,
replacement of a stale runner and a preserved user file, and repeats the version check. It needs Docker
and network access. For a real microVM or container use `apps/host/scripts/check-upgrade.mjs`
as documented in the host README. A real microVM check requires KVM.

Container service replacement identifies the exact Python script as its owner, repairs
stale or missing pid files, and verifies that the replacement process owns its listening
socket. Another process listening on the port never counts as successful readiness.
Container root can lack permission to inspect another user's process; identity and socket
inspection therefore run as `caboose`.

The real process regression checks run in an isolated Linux container:

```sh
docker run --rm --memory 512m --cpus 2 -v "$PWD/guest/components:/checks:ro" debian:trixie-slim bash -c 'apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends python3 && useradd -m -u 1000 caboose && python3 /checks/test_container_services.py -v'
```

They check replacement of loaded code with a lost pid file, preservation on an ordinary
start, and refusal to accept an unrelated listener as the replacement.

The bundle includes the owner keyring helper and its GNOME Keyring dependency. It installs
`caboose-session` only in container modes, including updates to existing containers; VM
lifecycle units remain managed by their image. Keyring initialization/unlock occurs through
the host after the Files service is ready, never inside the installer.

Linux VM images install `caboose-vsock-services.service`, which accepts host CID 2 on
vsock ports 14600, 14601, 14700 and 14701 and relays each to the corresponding loopback
TCP service. The bridge bounds concurrent connections and closes both ends on disconnect.
Container mode does not install it. At wake the host probes the Files bridge and falls back
to guest TCP when the bridge is unavailable.

`python3 guest/components/test_vsock_services.py` checks relay forwarding and cleanup
without KVM. On a running Linux microVM with Files ready, run
`python3 apps/host/scripts/check-vsock-services.py /path/to/desk.vsock` as the socket owner;
it checks the Cloud Hypervisor handshake and an HTTP response through the Files bridge.
