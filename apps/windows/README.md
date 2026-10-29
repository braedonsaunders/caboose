# Caboose for Windows

`CabooseSetup-windows-x64.exe` is the Windows 11 x64 desktop installer and tray app.
It imports a dedicated `Caboose` Debian 13 WSL2 distribution, installs the checksummed host
bundle from its own tagged release and configures the container runtime with `CABOOSE_GPU=wsl`.
Docker Engine runs inside this distribution; Docker Desktop is not required.

Open the executable and choose **Install / Update Caboose**. Windows asks for administrator
approval; approve as the same Windows login, because WSL distributions belong to a user.
WSL optional feature installation can require a restart. The installer registers a RunOnce
continuation and asks the owner to restart; it never shuts down another distribution.
Windows 11 build 22621 or later and WSL 2.0 or later are required. If WSL is absent entirely,
enable Windows Subsystem for Linux and Virtual Machine Platform in Windows Features first.
The installed app lives in `%LOCALAPPDATA%\Caboose` and starts at sign-in.

The native window shows an expiring single-use pairing QR, phone connection confirmation,
image download progress and Tailscale HTTPS controls. **Open Web Console** opens the local
one-time setup link when the host still needs an administrator account. Tailscale must be
installed and signed in inside the Caboose distribution for the host's HTTPS control to work.
The local owner token is read through WSL and remains in process memory; only the short-lived
pairing code appears in the QR and clipboard.

The installer embeds the existing transactional `setup-wsl.ps1`, boot runner `start-wsl.ps1`
and Linux installer at build time. It saves original Windows networking settings before
applying mirrored networking. Mirrored networking affects all WSL distributions and takes
effect on their next start. A distribution already named Caboose without this installer's
ownership record is rejected. Retrying installation resumes its downloads and import.

`caboose-agent.exe` provides `status`, `start`, `stop`, and `run-keepalive`. A scheduled task
named `Caboose-Start` runs it at startup and sign-in as the WSL owner's S4U principal, with
highest privileges and retries. The task starts Docker and the host before holding WSL open.
**Unattended cold-boot recovery requires the real-PC acceptance check below; configuring the
task alone does not establish that it works before sign-in on a particular Windows system.**

Uninstall in the native window removes startup and restores recorded Windows networking.
The distribution and computers remain. The separate, explicit data-deletion checkbox also
unregisters the distribution. CLI equivalents are `CabooseSetup --uninstall` and
`CabooseSetup --uninstall --purge`.

## Build

On a Windows x64 machine with the Rust MSVC toolchain and Visual Studio C++ build tools:

```powershell
$env:CABOOSE_VERSION = 'v0.2.0'
cargo build --release --locked --manifest-path apps/windows/Cargo.toml --bin caboose-agent
$env:CABOOSE_AGENT_PATH = (Resolve-Path apps/windows/target/release/caboose-agent.exe).Path
cargo build --release --locked --manifest-path apps/windows/Cargo.toml --bin CabooseSetup
Copy-Item apps/windows/target/release/CabooseSetup.exe CabooseSetup-windows-x64.exe
```

The agent is embedded in the setup executable. `CABOOSE_AGENT_PATH` must point to that exact
build when compiling GUI tests or checking all targets on Windows. Release downloads include
`caboose-wsl-rootfs-amd64.tar.gz`, built by `deploy/windows/build-rootfs.sh` on native Linux
amd64 with Docker, and `caboose-host-linux-amd64.tar.zst`; both must appear exactly once in
the release's `SHA256SUMS`. No setup path downloads scripts from a moving source branch.

## Check

Pure argument/link validation, bounded output draining, and process timeouts:

```sh
cargo test --locked --manifest-path apps/windows/Cargo.toml --lib
cargo fmt --manifest-path apps/windows/Cargo.toml --check
pwsh -NoProfile -File deploy/windows/setup-wsl.tests.ps1
pwsh -NoProfile -File deploy/windows/start-wsl.tests.ps1
```

On Windows, build the embedded agent first, then `cargo test --locked --manifest-path
apps/windows/Cargo.toml` and `cargo check --locked --all-targets --manifest-path
apps/windows/Cargo.toml`. `deploy/windows/check-consumer.ps1` checks the installed distribution,
service, scheduled task and direct network configuration without changing them. Its README
contains the manual cold-boot, reboot continuation and uninstall acceptance steps.
