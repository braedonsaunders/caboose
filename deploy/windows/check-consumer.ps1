# Read-only acceptance check; run elevated as the WSL owner after installation.
Set-StrictMode -Version 3
$ErrorActionPreference = 'Stop'
$root = Join-Path $env:LOCALAPPDATA 'Caboose'
$task = Get-ScheduledTask -TaskName 'Caboose-Start'
if ($task.Principal.LogonType -ne 'S4U' -or $task.Principal.RunLevel -ne 'Highest') { throw 'Startup task must use the WSL owner, S4U and highest privileges.' }
if ($task.State -ne 'Running') { throw 'Keepalive task is not running.' }
if (-not (Test-Path (Join-Path $root 'distribution-owned'))) { throw 'Missing distribution ownership record.' }
& (Join-Path $PSScriptRoot 'check.ps1') -Port 7310 -Distro Caboose
if ($LASTEXITCODE -ne 0) { throw 'Network acceptance failed.' }
& wsl.exe -d Caboose -u root --exec systemctl is-active docker caboose-host
if ($LASTEXITCODE -ne 0) { throw 'Services are not active.' }
$mode = & wsl.exe -d Caboose -u root --exec sh -c 'grep -E "^CABOOSE_(RUNTIME|GPU)=" /etc/caboose/host.env'
if ($LASTEXITCODE -ne 0 -or $mode -notcontains 'CABOOSE_RUNTIME=container' -or $mode -notcontains 'CABOOSE_GPU=wsl') { throw 'Wrong container or GPU configuration.' }
Write-Host 'Installed consumer host checks passed. Cold-boot-before-sign-in recovery still requires the separate acceptance procedure.'
