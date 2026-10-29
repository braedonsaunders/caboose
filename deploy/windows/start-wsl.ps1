<#
.SYNOPSIS
Brings a Caboose host in WSL up after Windows starts, with nobody signed in.

.DESCRIPTION
Meant for a scheduled task that runs at startup and at sign-in (see README.md, "Starting
with Windows"). Windows Update can restart the PC unattended; afterwards nothing starts WSL
until someone signs in, and a disk attached with `wsl --mount` is gone. This script:

1. attaches each -Vhd to WSL (`wsl --mount --vhd <path> --bare`), before the distribution
   starts, so its fstab mounts find it;
2. starts the distribution: through -KeepaliveTask, a scheduled task that keeps it running,
   or by keeping it running itself;
3. makes sure -MountPoint is mounted from a block device (never a loop-mounted image file),
   and only then starts each -Service in the distribution.

Running it again changes nothing that is already up: an attached disk, a running keepalive,
a mounted file system and an active service are left as they are. Each step is logged to
-Log.

.EXAMPLE
.\start-wsl.ps1 -Distro Ubuntu-24.04 -Vhd 'I:\Caboose\caboose-disks.vhdx' -MountPoint /home/me/caboose-disks -Service docker,caboose-host
#>
param(
    [string]$Distro,
    [string[]]$Vhd = @(),
    [string]$KeepaliveTask,
    [string]$MountPoint,
    [string[]]$Service = @('caboose-host'),
    [string]$Log = (Join-Path (Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'Caboose') 'start-wsl.log'),
    [int]$WaitSeconds = 180
)

Set-StrictMode -Version 3
$ErrorActionPreference = 'Stop'
$env:WSL_UTF8 = '1'
# A scheduled task runs this with -File, which passes `-Service docker,caboose-host` as one string.
$Service = @($Service | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })

function Write-Log([string]$Text) {
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Text"
    Write-Host $line
    if ($Log) {
        $directory = Split-Path -Parent $Log
        if ($directory -and -not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Force -Path $directory | Out-Null }
        Add-Content -LiteralPath $Log -Value $line
    }
}

# `wsl --mount` output for a disk WSL already has attached.
function Test-AlreadyAttached([string]$Output) { $Output -match 'ALREADY_ATTACHED|already attached|already mounted|SHARING_VIOLATION' }

# A file system mounted from a disk, not from a loop device over an image file.
function Test-BlockSource([string]$Source) { $Source -match '^/dev/(sd[a-z]+|vd[a-z]+|nvme\d+n\d+)(p?\d+)?$' }

# A single-quoted sh word.
function ConvertTo-ShWord([string]$Text) { "'" + ($Text -replace "'", "'\''") + "'" }

# Everything the script runs. Tests substitute their own.
function New-WslRunner {
    $distroArgs = @(); if ($Distro) { $distroArgs = @('-d', $Distro) }
    @{
        Ready      = { & wsl.exe --status *> $null; $LASTEXITCODE -eq 0 }
        Attach     = { param($Path) $out = (& wsl.exe --mount --vhd $Path --bare 2>&1) -join ' '; @{ ok = $LASTEXITCODE -eq 0; output = $out } }
        Running    = {
            $list = (& wsl.exe --list --running --quiet) -join "`n"
            if ($Distro) { $list -match "(?m)^\s*$([regex]::Escape($Distro))\s*$" } else { $list.Trim() -ne '' }
        }.GetNewClosure()
        TaskState  = { param($Name) "$((Get-ScheduledTask -TaskName $Name).State)" }
        StartTask  = { param($Name) Start-ScheduledTask -TaskName $Name }
        Shell      = { param($Command) $out = (& wsl.exe @distroArgs -u root --exec sh -c $Command 2>&1) -join "`n"; @{ ok = $LASTEXITCODE -eq 0; output = $out.Trim() } }.GetNewClosure()
        KeepAlive  = { & wsl.exe @distroArgs -u root --exec /bin/sleep infinity }.GetNewClosure()
        Sleep      = { param($Seconds) Start-Sleep -Seconds $Seconds }
    }
}

# Returns $true when every -Service was started (or already active).
function Invoke-Start($Run) {
    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    while (-not (& $Run.Ready)) {
        if ((Get-Date) -gt $deadline) { Write-Log 'WSL did not become available'; return $false }
        & $Run.Sleep 5
    }

    foreach ($path in $Vhd) {
        for ($try = 1; $try -le 3; $try++) {
            $result = & $Run.Attach $path
            if ($result.ok) { Write-Log "attached $path"; break }
            if (Test-AlreadyAttached $result.output) { Write-Log "$path is already attached"; break }
            Write-Log "attaching $path failed (try $try): $($result.output)"
            if ($try -lt 3) { & $Run.Sleep 5 }
        }
    }

    $ownKeepalive = -not $KeepaliveTask
    if ($KeepaliveTask) {
        if ((& $Run.TaskState $KeepaliveTask) -eq 'Running') { Write-Log "$KeepaliveTask is running" }
        else { & $Run.StartTask $KeepaliveTask; Write-Log "started $KeepaliveTask" }
    }
    # The distribution boots on its first command; with our own keepalive that is the mount check below.
    if ($KeepaliveTask) {
        while (-not (& $Run.Running)) {
            if ((Get-Date) -gt $deadline) { Write-Log 'the distribution did not start'; return $false }
            & $Run.Sleep 2
        }
    }

    if ($MountPoint) {
        $mp = ConvertTo-ShWord $MountPoint
        $result = & $Run.Shell "mountpoint -q $mp || mount $mp; findmnt -no SOURCE $mp"
        $source = "$($result.output)".Trim()
        if (-not (Test-BlockSource $source)) {
            Write-Log "not starting services: $MountPoint is not mounted from a disk (source '$source'): $($result.output)"
            if ($ownKeepalive) { & $Run.KeepAlive }
            return $false
        }
        Write-Log "$MountPoint is mounted from $source"
    }

    $started = $true
    foreach ($name in $Service) {
        $unit = ConvertTo-ShWord $name
        $result = & $Run.Shell "systemctl is-active -q $unit || systemctl start $unit; systemctl is-active $unit"
        if ($result.output -match '(^|\n)active$') { Write-Log "$name is active" }
        else { $started = $false; Write-Log "$name did not start: $($result.output)" }
    }

    if ($ownKeepalive) { Write-Log 'keeping the distribution running'; & $Run.KeepAlive }
    return $started
}

# Dot-sourcing only defines the functions, for start-wsl.tests.ps1.
if ($MyInvocation.InvocationName -ne '.') {
    Write-Log "start-wsl: distro=$Distro vhd=$($Vhd -join ',') keepalive=$KeepaliveTask mount=$MountPoint services=$($Service -join ',')"
    if (Invoke-Start (New-WslRunner)) { exit 0 } else { exit 1 }
}
