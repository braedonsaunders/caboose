# Caboose for macOS

The accessory menu app opens the host console, starts or stops the host LaunchAgent, and
opens its logs. It reads the install settings from
`~/Library/Application Support/Caboose/install.json`. While unclaimed, Open Caboose uses
the one-time code in `disks/setup-code`; it never reads or puts owner tokens in links.
Quitting the menu does not stop the host.

## Build

On an Apple Silicon Mac with macOS 14+ and Xcode command-line tools:

```sh
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

