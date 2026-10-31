# Native macOS host

Requires Apple Silicon, macOS 14 or later, and APFS for the computer disks. The per-user
installer needs neither Docker, Homebrew, nor administrator privileges. It installs the
bundled Node host, signed Virtualization.framework helper and Caboose menu bar app.

Download `Caboose-macos-arm64.dmg` from a release, drag Caboose to Applications and
open it. The app installs its bundled host for the current login and opens native phone
pairing; an unclaimed host first offers account creation in the web console.

The command-line path installs the same host:

```sh
bash deploy/macos/install.sh
```

Use `--version <tag>` for a particular release, or `--bundle <archive.tar.gz>` for a local
bundle. Downloads are verified against the release's SHA256SUMS. `--dry-run` prints paths;
`--no-start` installs without starting or opening anything.
`--stage-home <directory>` with `--no-start` stages files for checks without touching login services. Local builds are signed ad hoc;
release signing and notarization require the distributor's Apple credentials.

The command-line installer opens the local one-time setup link. Create the operator account, then use
the console's Remote Access page to connect Tailscale and enable Serve for HTTPS phone
access. The host listens on port 7310 by default. Existing Tailscale state is not changed
by installation.

The host and menu start at login, as LaunchAgents `com.caboose.host` and
`com.caboose.menu`. Logging out stops them; the Mac must be awake and the user logged in
to serve phones. Quitting only the menu leaves the host running.

## Settings and upgrades

Programs live in versioned directories under `~/Library/Application Support/Caboose`,
with `current` pointing to the selected version. `~/Applications/Caboose.app` points to
that version's menu app. Edit `install.json` in the data directory to change `port`,
`bind` (`0.0.0.0` or `127.0.0.1`), `memoryMb` or `vcpus`, then rerun the installer.
Defaults are port 7310, 3072 MiB and two vCPUs, with one running computer at a time.

Running the installer again stops the host, changes the selected version, and restarts it.
Upgrade and uninstall wait for launchd to unload the host before changing its program files.
If shutdown times out, they stop and retain the installed programs and computer data.
It retains settings and everything in `disks/`: accounts, computer disks and memory
snapshots. Logs are in `logs/`. The menu's Show Logs opens that directory.

```sh
bash deploy/macos/uninstall.sh
```

Uninstall removes programs and LaunchAgents but keeps computers and settings; reinstalling
uses them again. `--purge` also deletes all retained data and asks for confirmation;
`--purge --yes` confirms it non-interactively.

## Checks

```sh
bash apps/host/scripts/check-bundle.sh dist/release/caboose-host-darwin-arm64.tar.gz
bash deploy/macos/check.sh dist/release/caboose-host-darwin-arm64.tar.gz
bash deploy/macos/check-launchd.sh dist/release/caboose-host-darwin-arm64.tar.gz
```

The first starts a temporary local host and checks fresh account migrations and setup. The
second installs into a temporary home using `--stage-home` (which disables service operations), checking preserved
settings and data across upgrade, uninstall, reinstall and purge. It does not load real
LaunchAgents. The third uses a unique temporary LaunchAgent label, loopback port and data
directory to verify real start, stop, restart and retained host identity; it unloads the
test service afterward. The [native app README](../../apps/macos/README.md) covers the real VM and
manual menu checks.
