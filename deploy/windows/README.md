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
- records each original in `%ProgramData%\Caboose\wsl-networking.json` before it changes
  it: the networking mode, each firewall rule as it was (or that it did not exist), and each
  portproxy rule. The file is replaced atomically, and later runs keep the first run's
  originals. `-Revert` restores them one at a time, removing each from the file once it is
  back, so an interrupted apply or revert finishes when it is run again.

WSL reads its networking mode when it starts. `-Restart` runs `wsl --shutdown`, which stops
every running distribution (and anything attached with `wsl --mount`), then starts the
distribution again; without it, the change applies at the next WSL start.

## Requirements

- Windows 11 22H2 (build 22621) or later. Windows 10 has no mirrored networking; there a
  phone reaches WSL only through a forwarder, with the input delay described above.
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

With mirrored networking the Linux installer prints the PC's own addresses and a pairing QR
code. Under NAT networking, or when it cannot tell the mode (WSL older than 2.0 has no
`wslinfo`), it says that the distribution's own addresses are reachable only from Windows
and shows the command above; a configured `CABOOSE_PUBLIC_URL` still leads the pairing link.

| Option | Default | Meaning |
| --- | --- | --- |
| `-Port <ports>` | `7310` | The TCP ports to publish from WSL: the host's `CABOOSE_PORT`, and any other WSL service that a portproxy rule forwarded. Several ports need `-Command` rather than `-File`: `powershell -ExecutionPolicy Bypass -Command "& .\setup-wsl.ps1 -Port 7310,8188"`. |
| `-Profiles <names>` | `Any` | The firewall profiles the ports are open on: `Domain`, `Private`, `Public`. |
| `-Distro <name>` | the default distribution | The distribution to start after `-Restart`. |
| `-Restart` | | Restart WSL now. |
| `-Revert` | | Restore the networking mode, the firewall rules (a rule that existed gets its own enabled state, action and profiles back; one the script made is removed) and the portproxy rules. A `.wslconfig` the script created is removed. A restored portproxy rule keeps its old target, and WSL can give Linux another NAT address when it starts. |
| `-WhatIf` | | Print every change and make none. |

## Starting with Windows

Windows Update can restart the PC with nobody signed in. WSL then starts only when something
asks for it, and a disk attached with `wsl --mount` is no longer attached. `start-wsl.ps1`
brings the host back for a scheduled task that runs at startup and at sign-in:

1. it attaches each `-Vhd` with `wsl --mount --vhd <path> --bare` before the distribution
   starts, so the distribution's fstab mounts find it;
2. it starts the distribution through `-KeepaliveTask`, a scheduled task that keeps it running,
   or keeps it running itself;
3. it makes sure `-MountPoint` is mounted from a disk, never from a loop device over an image
   file, and only then starts each `-Service`.

A second run changes nothing that is already up. It logs each step to
`%ProgramData%\Caboose\start-wsl.log`. Register it to run as the user who owns the
distribution, whether or not that user is signed in, with highest privileges (attaching a
disk needs them):

```powershell
$arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "C:\Caboose\start-wsl.ps1" ' +
  '-Distro Ubuntu-24.04 -MountPoint /var/lib/caboose -Service docker,caboose-host'
Register-ScheduledTask -TaskName 'Caboose-Start' `
  -Action (New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arguments) `
  -Trigger (New-ScheduledTaskTrigger -AtStartup), (New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME") `
  -Principal (New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType S4U -RunLevel Highest) `
  -Settings (New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero))
```

Add `-Vhd <path>` for a data disk kept outside the distribution.

## Checks

`setup-wsl.tests.ps1` tests the script's logic: editing `.wslconfig`, reading netsh's
portproxy table, and applying and reverting against a machine in memory, including runs
interrupted after the `.wslconfig` write, after the firewall rule and after each portproxy
deletion, and a firewall rule that existed before. It needs no administrator or WSL, and
runs in Windows PowerShell 5.1 or in `pwsh` on any system:

```sh
pwsh -NoProfile -File deploy/windows/setup-wsl.tests.ps1
```

`start-wsl.tests.ps1` tests the order of `start-wsl.ps1`'s steps and what it refuses to do (no
service starts on a missing disk or a loop-mounted image), against a recorded runner:

```sh
pwsh -NoProfile -File deploy/windows/start-wsl.tests.ps1
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
