# Caboose on Linux

One command installs Caboose natively, without Docker: the caboose-host bundle from a
GitHub Release, a systemd service, and the computer's disk. The host then fetches the
computer's image itself.

```sh
curl -fsSL https://raw.githubusercontent.com/braedonsaunders/caboose/main/deploy/linux/install.sh | sudo bash
```

At the end it prints the console's address, the setup link while the host is unclaimed,
where to find the owner token, and a QR code.
Scan the QR code with the iPhone's Camera within 10 minutes to sign the Caboose app in. Make a
new code later in the console: open your computer under **Computers**, then **Phones › Sign in a phone**.

## What you need

- Linux on amd64 or arm64, with systemd.
- For the microVM runtime (the default): hardware virtualization, i.e. `/dev/kvm`. On a PC,
  turn on Intel VT-x or AMD-V (often called SVM) in the firmware settings. In a virtual
  machine, enable nested virtualization.
- For the container runtime (`--runtime container`): Docker Engine. Use it where a GPU can
  reach a container but not a VM (docs/architecture.md, Runtimes).
- Free disk space for the computer. Its disk grows as it is used, up to `--disk-size`.

The installer adds what is missing (curl, zstd, iproute2, iptables, xfsprogs, and qrencode
for the QR code) with apt, dnf, pacman or zypper.

## What it changes

| Path | What |
| --- | --- |
| `/opt/caboose/<version>`, `/opt/caboose/current` | The host bundle (apps/host/README.md, Bundle). The previous version is kept for a rollback. |
| `/usr/local/bin/caboose-host` | The host's launcher. |
| `/etc/caboose/host.env` (0600) | Settings (apps/host/README.md, Configuration). Written once; an upgrade adds only missing keys. |
| `/etc/systemd/system/caboose-host.service` | Runs the host as root: it needs `/dev/kvm`, a TAP device and iptables for the computer's fenced network. Stopping it parks the computer with its memory. |
| `/var/lib/caboose/disks` | The computer, its snapshots, and the host's state, including the generated `owner-token` (0600). When the filesystem cannot make reflink clones, it is a sparse XFS image, `/var/lib/caboose/disks.xfs.img`, mounted through `/etc/fstab`. |

The host listens on every address on port 7310 by default, so a phone on the same network
reaches it. Traffic is plain HTTP on that network. To use Caboose away from home, use
Tailscale or a server with a domain and HTTPS (`--domain`, [deploy/server](../server)).
Never forward the port from your router.

## Options

| Option | Default | Meaning |
| --- | --- | --- |
| `--version <tag>` | the latest release | The release to install. |
| `--bundle <path>` | download | Install a local `caboose-host-linux-<arch>.tar.zst` (from `apps/host/scripts/bundle.sh`). |
| `--runtime microvm\|container` | `microvm` | How the computer runs. |
| `--bind <address>` | `0.0.0.0` | The listen address. `127.0.0.1` keeps it to this machine. |
| `--port <port>` | `7310` | The listen port. |
| `--state-dir <path>` | `/var/lib/caboose` | Where the computer and the host's state live. |
| `--disk-size <size>` | `400G` | The maximum size of the XFS disk image, when one is made. |
| `--domain <name>` | | Set up a server with automatic HTTPS for this domain instead ([deploy/server](../server)). |
| `--email <address>` | | With `--domain`, the ACME account email. |
| `--force` | | Install even without `/dev/kvm`, for instance to prepare a machine. |
| `--no-start` | | Install without starting the service. |
| `--dry-run` | | Print what would happen and change nothing. |

Pass options after `bash -s --`:

```sh
curl -fsSL …/install.sh | sudo bash -s -- --runtime container --port 8080
```

## Upgrade, uninstall

Run the installer again to upgrade. The computer, its settings and the owner token stay.
Saved runtime, bind address, port and state directory take precedence over installer flags;
edit `/etc/caboose/host.env` to change them.

```sh
sudo bash deploy/linux/uninstall.sh            # removes the service and program, keeps the computer
sudo bash deploy/linux/uninstall.sh --purge    # also deletes the computer and settings (asks first)
```

## Checks

`deploy/linux/check.sh [bundle]` runs the installer in a Debian 13 container with systemd. It
checks:
- that a dry run changes nothing;
- the install: the service, the API with the owner token, private settings and token, an XFS
  disk root, and the printed pairing link;
- an upgrade that keeps settings;
- an uninstall that keeps the computer, and a reinstall that finds it again;
- a purge.

The container has no `/dev/kvm`, so it installs with `--force` and does not wake a computer.
On a real KVM machine, run the installer and then `apps/host/scripts/e2e.sh` (apps/host/README.md, Real-host checks).
