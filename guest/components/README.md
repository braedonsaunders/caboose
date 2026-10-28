# Guest components

The manifest lists the exact files shipped by the host. `version.py` and the host hash the
ordered file names and bytes identically. `install.sh` installs missing dependencies,
updates system-owned files (including the agent runner and its pinned npm dependencies), configures services and writes the version marker only after
success. It never modifies the owner's home. Both image builders call it in image mode;
the host calls it through root guest exec in `vm` or `container` mode after display readiness.
The installer preserves working `node` and `npm` commands, including npm bundled with
NodeSource's `nodejs`. It installs Node when unusable, then checks npm again before
requesting Debian's separate `npm` package. Both commands must run before system files
are updated. The installer is safe to repeat. The Thunar action is a system default: user
custom actions can override it. See `docs/architecture.md` § Guest for the API and
older-container caveat.

From the repository root, `python3 guest/components/test_install.py` checks dependency
detection and APT failures with isolated shell fixtures. It needs Bash and Python 3, runs
without root, Docker or network access, and stops before the first system-file write.

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
