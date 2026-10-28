# Caboose on Windows

CabooseSetup installs the host in a dedicated WSL 2 distribution named `Caboose` with its own Docker Engine. It requires an x64 PC, Windows 10 22H2 or Windows 11, virtualization enabled, and administrator access. The computer runs as a container; its home and installed applications live in the distribution. Container parking keeps memory in RAM and does not survive a host restart.

Run `CabooseSetup.exe` as the user who will own the distribution. Setup can install WSL, import a verified release rootfs, install a startup task and open the console. If offered, mirrored networking changes `.wslconfig` for **all** of the user's WSL distributions and restarts WSL. Otherwise a Windows port proxy forwards port 7310 to the distribution. Firewall rules allow the private network profile. To finish first-run setup, open Caboose from its notification-area icon; the icon reads the one-time setup code from the distribution. The console pairs the iPhone.

Run setup again to upgrade or repair. `CabooseSetup.exe --uninstall` removes the Windows integration and keeps the distribution and its data; the uninstall dialog offers to delete it. `--uninstall --yes --delete-data` deletes it without a dialog. `--yes` accepts recommended options unattended; `--distro <path> [--sha256 <hex>]` uses a local rootfs, and `--release <tag>` chooses a release. Setup logs to `%LOCALAPPDATA%\Caboose\logs\setup.log`; the startup task logs to `service.log` there. The host and computer state are in the distribution under `/var/lib/caboose` and `/var/lib/docker`.

## Build and check

With Rust and the MSVC build tools on Windows:

```powershell
cd apps/windows
cargo test --workspace --locked
cargo build --release --locked -p caboose-service -p caboose-tray
$env:CABOOSE_EMBED_DIR = (Resolve-Path target/release).Path
cargo build --release --locked -p caboose-setup
```

The resulting `target/release/CabooseSetup.exe` embeds the service and tray. Without `CABOOSE_EMBED_DIR`, setup uses their executables beside it. Release setup downloads `caboose-wsl-amd64.tar.gz` and its checksum from GitHub Releases. Build and test that rootfs with `deploy/windows/distro/build.sh` and `check.sh`; the latter boots systemd in an isolated privileged Docker container. Run `powershell -File apps/windows/check.ps1` on a Windows installation to check its distribution, host and startup task. The check does not install, reboot, unregister or alter a distribution.
