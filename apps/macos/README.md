# Caboose for macOS

The menu bar app installs the bundled host on first launch, then opens a native iPhone
pairing window. It reads settings from `~/Library/Application Support/Caboose/install.json`
and uses the local `disks/owner-token` only as a bearer header to the loopback host API.
QR codes contain single-use, ten-minute pairing codes and reachable host addresses.
The window shows image download progress, detects newly signed-in phones and offers
Tailscale HTTPS. An unclaimed host offers the one-time web setup link first.
**Pair iPhone…** reopens the window; closing it stops polling. The menu also opens the
console and logs and controls the host LaunchAgent. Quitting the menu leaves the host running.

## Build

On an Apple Silicon Mac with macOS 14+ and Xcode command-line tools:

```sh
swift test --package-path apps/macos --disable-sandbox -j 2
bash apps/macos/scripts/build.sh /tmp/caboose-menu
```

This builds `Caboose.app` and verifies its signature. The default signature is ad hoc for
local builds. Set `CABOOSE_CODESIGN_IDENTITY` to a signing identity for a distribution
build. The native VM helper is built separately by the AppKit package with its
virtualization entitlement; `apps/host/scripts/bundle.sh darwin arm64 dist/release`
packages both with the host and console.

## Check

The [installer check](../../deploy/macos/README.md#checks) tests the file installation
without changing login services. The controller check needs a signed VZ helper, a built
arm64 guest image (`base.raw`, `vmlinux`, `initrd`), and enough memory for the guest:

```sh
CABOOSE_CHECK_IMAGE_ROOT=/absolute/path/to/arm64-image \
CABOOSE_VMM_PATH=/absolute/path/to/appkit-desk-vz \
pnpm --filter caboose-host exec tsx scripts/check-macos.mts
```

It boots a disposable overlay, checks display protocol hello and file/terminal relays,
parks and restores memory, and checks that the guest boot identity and display survive.
It removes the overlay and snapshot afterward; it never changes the supplied base image.
`CABOOSE_CHECK_MEMORY_MB` overrides the check's 1536 MiB memory allocation.
Set `CABOOSE_CHECK_CONSOLE=1` to include the guest's serial console on failure; the default
checks the same silent serial attachment used by the installed host.

For a manual menu check after installation, open Caboose, verify its running/setup status,
open the console, stop and start the host, then quit the menu and confirm the host stays up.


## Consumer app and disk image

The Darwin host bundle includes `Caboose.app` with `Contents/Resources/runtime.tar.gz`,
`install.sh` and `VERSION`. The embedded archive contains a complete host and a bare menu
app, without a nested archive. On a version change the outer app runs the bundled installer
with `--from-app`, preserving settings and computer disks. That mode leaves the current
menu process alive and starts only the host; the login menu uses the installed version.
Launching the app can restart the host when its bundled version differs from the installed one.

```sh
bash deploy/macos/package-dmg.sh dist/release/caboose-host-darwin-arm64.tar.gz dist/release/Caboose-macos-arm64.dmg
```

To check the consumer flow on a separate macOS login, drag the app from the DMG to
Applications and open it. Confirm host installation without Terminal, complete account
setup, scan the QR on an iPhone and observe its name appear. Renew a code, let it expire,
check that its QR disappears, and enable Tailscale HTTPS with both devices signed into
the same tailnet. Close the window and reopen it from the menu. Quit and reopen the app,
then log out and in to confirm the host and menu start from the installed directory.
With an older bundle installed, launch a newer app and verify settings and computer files
survive. This check changes that login's Caboose LaunchAgents; do not run it on a production login.
