# Guest components

The manifest lists the exact files shipped by the host. `version.py` and the host hash the
ordered file names and bytes identically. `install.sh` installs only missing Debian packages,
updates system-owned files, configures services and writes the version marker only after
success. It never modifies the owner's home. Both image builders call it in image mode;
the host calls it through root guest exec in `vm` or `container` mode after display readiness.
The installer is safe to repeat. The Thunar action is a system default: user custom actions
can override it. See `docs/architecture.md` § Guest for the API and older-container caveat.

From the repository root, `pnpm install` then `guest/components/check-container.sh` starts
a disposable Debian guest without components, upgrades it over the same exec transport,
checks services (the terminal service on 14701 runs as the owner and refuses a missing token) and a preserved user file, and repeats the version check. It needs Docker
and network access. For a real microVM or container use `apps/host/scripts/check-upgrade.mjs`
as documented in the host README. A real microVM check requires KVM.
