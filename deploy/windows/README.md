# Caboose on Windows

On Windows, Caboose runs in WSL2: the [Linux installer](../linux/README.md) inside a WSL
distribution, with the GPU container runtime (`--runtime container`, which reaches the
GPU through WSL's `/dev/dxg`). `setup-wsl.ps1` prepares Windows so phones reach that host
directly.

## Networking

By default WSL puts Linux behind NAT, on a virtual network that only Windows reaches. Phones
on the LAN or the tailnet would need something on Windows to forward a port into it, such as
`netsh interface portproxy`. Such a forwarder holds each small message from the phone (a
touch, a display refresh tick, a frame acknowledgement) until WSL acknowledges the one
before it, and Linux delays that acknowledgement by up to 40 ms. Input then reaches
applications in bursts, and pictures wait for their acknowledgements, so scrolling stutters.

Mirrored networking removes the forwarder: Linux shares the PC's own interfaces and
addresses (Ethernet, Wi-Fi, Tailscale), and the phone's connection goes straight to
caboose-host. `setup-wsl.ps1`:

- sets `networkingMode=mirrored` in `%USERPROFILE%\.wslconfig`, keeping every other setting;
- allows the host's TCP port into WSL through the Hyper-V firewall, which guards WSL's
  inbound traffic in mirrored mode (rule `Caboose-WSL-TCP-<port>`);
- deletes `netsh interface portproxy` rules on that port, which would otherwise take the
  port on Windows before WSL sees it;
- warns about other portproxy rules: they forward into WSL's NAT address, which mirrored
  networking does not have. Pass their ports to `-Port` to publish those services the same way;
- records what it changed in `%ProgramData%\Caboose\wsl-networking.json`, so `-Revert`
  restores it.

WSL reads its networking mode when it starts. `-Restart` runs `wsl --shutdown`, which stops
every running distribution (and anything attached with `wsl --mount`), then starts the
distribution again; without it, the change applies at the next WSL start.

## Requirements

- Windows 11 22H2 (build 22621) or later.
- WSL 2.0 or later, from the Microsoft Store (`wsl --update`).
- An elevated PowerShell, run as the Windows user who runs WSL.

## Use

In an administrator PowerShell:

```powershell
irm https://raw.githubusercontent.com/braedonsaunders/caboose/main/deploy/windows/setup-wsl.ps1 -OutFile setup-wsl.ps1
powershell -ExecutionPolicy Bypass -File setup-wsl.ps1 -Restart
```

Then install Caboose inside the distribution:

```sh
curl -fsSL https://raw.githubusercontent.com/braedonsaunders/caboose/main/deploy/linux/install.sh | sudo bash -s -- --runtime container
```

The Linux installer prints the PC's own addresses and a pairing QR code. In a WSL
distribution that still uses NAT networking it prints no pairing link and shows the
command above instead.

| Option | Default | Meaning |
| --- | --- | --- |
| `-Port <ports>` | `7310` | The TCP ports to publish from WSL: the host's `CABOOSE_PORT`, and any other WSL service that a portproxy rule forwarded. Several ports need `-Command` rather than `-File`: `powershell -ExecutionPolicy Bypass -Command "& .\setup-wsl.ps1 -Port 7310,8188"`. |
| `-Profiles <names>` | `Any` | The firewall profiles the ports are open on: `Domain`, `Private`, `Public`. |
| `-Distro <name>` | the default distribution | The distribution to start after `-Restart`. |
| `-Restart` | | Restart WSL now. |
| `-Revert` | | Restore the networking mode, firewall rules and portproxy rules from before. A restored portproxy rule keeps its old target, and WSL can give Linux another NAT address when it starts. |
| `-WhatIf` | | Print every change and make none. |

## Checks

`setup-wsl.tests.ps1` tests the script's pure logic (editing `.wslconfig`, reading netsh's
portproxy table). It needs no administrator or WSL, and runs in Windows PowerShell 5.1 or
in `pwsh` on any system:

```sh
pwsh -NoProfile -File deploy/windows/setup-wsl.tests.ps1
```

`check.ps1` checks a real PC without changing it, in an elevated PowerShell after setup and a
WSL restart: the configured and running networking mode, the Hyper-V firewall rule, that no
portproxy rule takes the port, and that caboose-host answers on it. It prints the addresses
a phone uses, and exits non-zero when a check fails:

```powershell
powershell -ExecutionPolicy Bypass -File check.ps1 -Port 7310 -Distro Ubuntu-24.04
```

To confirm a phone's connection is direct, connect the phone and run, inside WSL,
`ss -tn state established sport = :7310`. The peer is the phone's own address, not
`172.x.0.1`.
