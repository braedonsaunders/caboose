# Invoked by the Rust installer, elevated as the same Windows login that owns WSL.
param([Parameter(Mandatory=$true)][string]$Version, [switch]$Uninstall, [switch]$Purge)
Set-StrictMode -Version 3
$ErrorActionPreference = 'Stop'
$env:WSL_UTF8 = '1'
if ($env:PROCESSOR_ARCHITECTURE -ne 'AMD64') { throw 'This installer requires x64 Windows 11.' }
$root = $PSScriptRoot
trap { [IO.File]::WriteAllText((Join-Path $PSScriptRoot 'install-error.txt'), $_.ToString()); exit 1 }
Remove-Item (Join-Path $root 'install-error.txt') -ErrorAction SilentlyContinue
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Administrator privileges are required.' }
if ([int](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').CurrentBuildNumber -lt 22621) { throw 'Requires Windows 11 build 22621 or later.' }
$ownerFile = Join-Path $root 'owner-sid'
if ((Get-Content $ownerFile -Raw).Trim() -ne $identity.User.Value) { throw 'Elevate with the same Windows account; WSL distributions belong to that account.' }
. (Join-Path $root 'start-wsl.ps1')
function Native([string]$File, [string[]]$Arguments, [int]$Seconds = 600) {
    $result = Invoke-Native $File $Arguments $Seconds
    if (-not $result.ok) { throw "$File failed: $($result.output)" }
    return $result.output
}
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
if ($Uninstall) {
    if (Get-ScheduledTask -TaskName 'Caboose-Start' -ErrorAction SilentlyContinue) {
        Stop-ScheduledTask -TaskName 'Caboose-Start'
        Unregister-ScheduledTask -TaskName 'Caboose-Start' -Confirm:$false
    }
    Remove-ItemProperty $runKey -Name Caboose -ErrorAction SilentlyContinue
    $distros = Native 'wsl.exe' @('--list','--quiet')
    if ($distros -match '(?m)^\s*Caboose\s*$') { Native 'wsl.exe' @('-d','Caboose','-u','root','--exec','systemctl','stop','caboose-host') | Out-Null }
    if (Test-Path (Join-Path $env:ProgramData 'Caboose\wsl-networking.json')) { & (Join-Path $root 'setup-wsl.ps1') -Revert }
    if ($Purge) {
        if (-not (Test-Path (Join-Path $root 'distribution-owned'))) { throw 'No ownership record; refusing to remove a distribution.' }
        Native 'wsl.exe' @('--unregister','Caboose') | Out-Null
        Remove-Item (Join-Path $root 'distribution-owned')
    }
    Write-Host 'Caboose startup removed. Distribution and computers are retained unless --purge was selected.'
    exit 0
}
if ($Version -notmatch '^v[A-Za-z0-9._+-]+$') { throw 'Installer must be built for a tagged release.' }
# A private application directory contains privileged startup executables: other users cannot write it.
$acl = New-Object Security.AccessControl.DirectorySecurity
$acl.SetAccessRuleProtection($true,$false)
foreach ($sid in @($identity.User.Value,'S-1-5-18','S-1-5-32-544')) {
    $rule = New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier($sid)),'FullControl','ContainerInherit,ObjectInherit','None','Allow')
    $acl.AddAccessRule($rule)
}
Set-Acl -LiteralPath $root -AclObject $acl
$wsl = Get-Command wsl.exe -ErrorAction SilentlyContinue
$ready = $false
if ($wsl) { $probe = Invoke-Native 'wsl.exe' @('--version') 30; $ready = $probe.ok -and $probe.output -match '(\d+)\.(\d+)\.(\d+)' -and [int]$Matches[1] -ge 2 }
if (-not $ready) {
    if (-not $wsl) { throw 'WSL is not available. Enable Windows Subsystem for Linux and Virtual Machine Platform in Windows Features, restart, and open Caboose again.' }
    $result = Invoke-Native 'wsl.exe' @('--install','--no-distribution','--no-launch') 1200
    # Installation of optional Windows features needs a reboot. Continue after sign-in;
    # never restart Windows or another person's WSL distributions implicitly.
    $once = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
    New-Item $once -Force | Out-Null
    New-ItemProperty $once -Name CabooseSetup -Value ('"' + (Join-Path $root "CabooseSetup-$Version.exe") + '"') -Force | Out-Null
    if (-not $result.ok -and $result.output -notmatch 'reboot|restart|3010') { throw "WSL installation failed: $($result.output)" }
    Write-Host 'Restart Windows, then open Caboose again to finish installation.'
    exit 3010
}
& (Join-Path $root 'setup-wsl.ps1') -Distro Caboose
if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw 'Networking configuration failed.' }
$distros = Native 'wsl.exe' @('--list','--quiet')
if ($distros -match '(?m)^\s*Caboose\s*$' -and -not (Test-Path (Join-Path $root 'distribution-owned'))) { throw 'A distribution named Caboose already exists and is not owned by this installer.' }
$base = "https://github.com/braedonsaunders/caboose/releases/download/$Version"
$downloads = Join-Path $root 'downloads'
New-Item -ItemType Directory -Path $downloads -Force | Out-Null
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Invoke-WebRequest -UseBasicParsing "$base/SHA256SUMS" -OutFile (Join-Path $downloads 'SHA256SUMS')
$checksums = Get-Content (Join-Path $downloads 'SHA256SUMS')
function Download([string]$Name) {
    $matches = @($checksums | Where-Object { $_ -match ('^[a-f0-9]{64}\s+\*?' + [regex]::Escape($Name) + '$') })
    if ($matches.Count -ne 1) { throw "Release checksum missing or ambiguous: $Name" }
    $hash = ($matches[0] -split '\s+')[0]
    $file = Join-Path $downloads $Name
    if (-not (Test-Path $file) -or (Get-FileHash $file -Algorithm SHA256).Hash.ToLowerInvariant() -ne $hash) {
        Invoke-WebRequest -UseBasicParsing "$base/$Name" -OutFile "$file.part"
        if ((Get-FileHash "$file.part" -Algorithm SHA256).Hash.ToLowerInvariant() -ne $hash) { throw "Checksum mismatch: $Name" }
        Move-Item "$file.part" $file -Force
    }
    return $file
}
if ($distros -notmatch '(?m)^\s*Caboose\s*$') {
    $image = Download 'caboose-wsl-rootfs-amd64.tar.gz'
    # Record intent before import so interrupted installation is resumable.
    [IO.File]::WriteAllText((Join-Path $root 'distribution-owned'),$identity.User.Value)
    Native 'wsl.exe' @('--import','Caboose',(Join-Path $root 'distribution'),$image,'--version','2') 1200 | Out-Null
}
$bundle = Download 'caboose-host-linux-amd64.tar.zst'
# wslpath receives an argument, never interpolated shell input.
$linuxBundle = Native 'wsl.exe' @('-d','Caboose','-u','root','--exec','wslpath','-u',$bundle)
$linuxInstaller = Native 'wsl.exe' @('-d','Caboose','-u','root','--exec','wslpath','-u',(Join-Path $root 'linux-install.sh'))
Native 'wsl.exe' @('-d','Caboose','-u','root','--exec','systemctl','start','docker') | Out-Null
Native 'wsl.exe' @('-d','Caboose','-u','root','--exec','bash',$linuxInstaller,'--bundle',$linuxBundle,'--runtime','container') 1800 | Out-Null
Native 'wsl.exe' @('-d','Caboose','-u','root','--exec','sh','-c','grep -q "^CABOOSE_GPU=" /etc/caboose/host.env || printf "\nCABOOSE_GPU=wsl\n" >> /etc/caboose/host.env') | Out-Null
Native 'wsl.exe' @('-d','Caboose','-u','root','--exec','systemctl','restart','caboose-host') | Out-Null
if (Get-ScheduledTask -TaskName 'Caboose-Start' -ErrorAction SilentlyContinue) {
    Stop-ScheduledTask -TaskName 'Caboose-Start'
    Start-Sleep -Seconds 2
}
Copy-Item (Join-Path $root 'agent-payload.exe') (Join-Path $root 'caboose-agent.exe') -Force
$user = $identity.Name
Register-ScheduledTask -TaskName 'Caboose-Start' -Force `
  -Action (New-ScheduledTaskAction -Execute (Join-Path $root 'caboose-agent.exe') -Argument 'run-keepalive' -WorkingDirectory $root) `
  -Trigger (New-ScheduledTaskTrigger -AtStartup), (New-ScheduledTaskTrigger -AtLogOn -User $user) `
  -Principal (New-ScheduledTaskPrincipal -UserId $user -LogonType S4U -RunLevel Highest) `
  -Settings (New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero)) | Out-Null
New-Item $runKey -Force | Out-Null
New-ItemProperty $runKey -Name Caboose -Value ('"' + (Join-Path $root "CabooseSetup-$Version.exe") + '" --tray') -Force | Out-Null
Start-ScheduledTask -TaskName 'Caboose-Start'
Write-Host 'Installed. Open Caboose to pair your iPhone. Mirrored networking applies at the next WSL start if another distribution was already running.'
