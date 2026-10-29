<#
.SYNOPSIS
Brings a Caboose host in WSL up after Windows starts, with nobody signed in.

.DESCRIPTION
Meant for a scheduled task that runs at startup and at sign-in (see README.md, "Starting
with Windows"). Windows Update can restart the PC unattended; afterwards nothing starts WSL
until someone signs in, and a disk attached with `wsl --mount` is gone. This script:

1. attaches each -Vhd to WSL (`wsl --mount --vhd <path> --bare`) before the distribution
   starts, so its fstab mounts find it, and stops if a disk cannot be attached;
2. starts the distribution: through -KeepaliveTask, a scheduled task that keeps it running,
   or by keeping it running itself once everything is up;
3. makes sure -MountPoint is mounted from a disk (never a loop device over an image file),
   with file system -Uuid when given, and only then starts each -Service.

It exits 1 when a step fails, so the task's restart settings try again; every wsl.exe call
is bounded by a timeout, so a hung call does not stall the retries. Running it again changes
nothing that is already up. Each step is logged to -Log.

.EXAMPLE
.\start-wsl.ps1 -Distro Ubuntu-24.04 -Vhd 'I:\Caboose\caboose-disks.vhdx' -MountPoint /home/me/caboose-disks -Uuid 6d0eb1d8-c917-4b5d-a9b1-e596614cc6d4 -Service docker,caboose-host
#>
param(
    [string]$Distro,
    [string[]]$Vhd = @(),
    [string]$KeepaliveTask,
    [string]$MountPoint,
    [string]$Uuid,
    [string[]]$Service = @('caboose-host'),
    [string]$Log = (Join-Path (Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'Caboose') 'start-wsl.log'),
    [int]$WaitSeconds = 180
)

Set-StrictMode -Version 3
$ErrorActionPreference = 'Stop'
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

# One command-line argument as the Microsoft C runtime parses it back.
function ConvertTo-WindowsArgument([string]$Text) {
    if ($Text -ne '' -and $Text -notmatch '[\s"]') { return $Text }
    $out = New-Object System.Text.StringBuilder
    [void]$out.Append('"')
    $slashes = 0
    foreach ($c in $Text.ToCharArray()) {
        if ($c -eq '\') { $slashes++; continue }
        if ($c -eq '"') { [void]$out.Append('\' * ($slashes * 2 + 1)); [void]$out.Append('"') }
        else { if ($slashes) { [void]$out.Append('\' * $slashes) }; [void]$out.Append($c) }
        $slashes = 0
    }
    [void]$out.Append('\' * ($slashes * 2))
    [void]$out.Append('"')
    return $out.ToString()
}

# Runs a program, killing it after $TimeoutSeconds. Output is stdout and stderr together.
function Invoke-Native([string]$File, [string[]]$Arguments, [int]$TimeoutSeconds) {
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $File
    $info.Arguments = ($Arguments | ForEach-Object { ConvertTo-WindowsArgument $_ }) -join ' '
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.EnvironmentVariables['WSL_UTF8'] = '1'
    $process = [System.Diagnostics.Process]::Start($info)
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        try { $process.Kill() } catch { }
        return @{ ok = $false; output = "timed out after $TimeoutSeconds s: $File $($info.Arguments)" }
    }
    $process.WaitForExit()
    return @{ ok = $process.ExitCode -eq 0; output = (($stdout.Result + $stderr.Result) -replace "`0", '').Trim() }
}

# Everything the script runs. Tests substitute their own.
function New-WslRunner {
    $distroArgs = @(); if ($Distro) { $distroArgs = @('-d', $Distro) }
    @{
        Ready     = { (Invoke-Native 'wsl.exe' @('--status') 30).ok }
        Attach    = { param($Path) Invoke-Native 'wsl.exe' @('--mount', '--vhd', $Path, '--bare') 90 }
        Running   = {
            $list = Invoke-Native 'wsl.exe' @('--list', '--running', '--quiet') 30
            if (-not $list.ok) { return $false }
            if ($Distro) { $list.output -match "(?m)^\s*$([regex]::Escape($Distro))\s*$" } else { $list.output -ne '' }
        }.GetNewClosure()
        TaskState = { param($Name) "$((Get-ScheduledTask -TaskName $Name).State)" }
        StartTask = { param($Name) Start-ScheduledTask -TaskName $Name }
        Shell     = { param($Command) Invoke-Native 'wsl.exe' ($distroArgs + @('-u', 'root', '--exec', 'sh', '-c', $Command)) 150 }.GetNewClosure()
        # The keepalive runs for as long as the PC does: it is the one call without a timeout.
        KeepAlive = { & wsl.exe @distroArgs -u root --exec /bin/sleep infinity }.GetNewClosure()
        Sleep     = { param($Seconds) Start-Sleep -Seconds $Seconds }
    }
}

# $true once every -Service is active; $false, with the reason logged, at the first failure.
function Invoke-Start($Run) {
    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    while (-not (& $Run.Ready)) {
        if ((Get-Date) -gt $deadline) { Write-Log 'stopping: WSL did not become available'; return $false }
        & $Run.Sleep 5
    }

    foreach ($path in $Vhd) {
        $attached = $false
        for ($try = 1; $try -le 3 -and -not $attached; $try++) {
            $result = & $Run.Attach $path
            if ($result.ok) { Write-Log "attached $path"; $attached = $true }
            elseif (Test-AlreadyAttached $result.output) { Write-Log "$path is already attached"; $attached = $true }
            else {
                Write-Log "attaching $path failed (try $try): $($result.output)"
                if ($try -lt 3) { & $Run.Sleep 5 }
            }
        }
        if (-not $attached) { Write-Log "stopping: $path is not attached"; return $false }
    }

    if ($KeepaliveTask) {
        if ((& $Run.TaskState $KeepaliveTask) -eq 'Running') { Write-Log "$KeepaliveTask is running" }
        else { & $Run.StartTask $KeepaliveTask; Write-Log "started $KeepaliveTask" }
        while (-not (& $Run.Running)) {
            if ((Get-Date) -gt $deadline) { Write-Log 'stopping: the distribution did not start'; return $false }
            & $Run.Sleep 2
        }
    }
    # Without a keepalive task the distribution boots on the first command below.

    if ($MountPoint) {
        $mp = ConvertTo-ShWord $MountPoint
        $result = & $Run.Shell "mountpoint -q $mp || mount $mp; findmnt -no SOURCE,UUID $mp"
        $fields = @("$($result.output)".Trim() -split '\s+')
        $source = $fields[0]
        $found = ''; if ($fields.Count -gt 1) { $found = $fields[1] }
        if (-not $result.ok -or -not (Test-BlockSource $source) -or ($Uuid -and $found -ne $Uuid)) {
            $expected = ''; if ($Uuid) { $expected = ", expected $Uuid" }
            Write-Log "stopping: $MountPoint is not mounted from the expected disk (source '$source', UUID '$found'$expected): $($result.output)"
            return $false
        }
        Write-Log "$MountPoint is mounted from $source ($found)"
    }

    foreach ($name in $Service) {
        $unit = ConvertTo-ShWord $name
        $result = & $Run.Shell "systemctl is-active -q $unit || systemctl start $unit; systemctl is-active $unit"
        if ($result.ok -and "$($result.output)" -match '(^|\n)active$') { Write-Log "$name is active" }
        else { Write-Log "stopping: $name did not start: $($result.output)"; return $false }
    }

    if (-not $KeepaliveTask) { Write-Log 'keeping the distribution running'; & $Run.KeepAlive }
    return $true
}

# Dot-sourcing only defines the functions, for start-wsl.tests.ps1.
if ($MyInvocation.InvocationName -ne '.') {
    Write-Log "start-wsl: distro=$Distro vhd=$($Vhd -join ',') keepalive=$KeepaliveTask mount=$MountPoint uuid=$Uuid services=$($Service -join ',')"
    if (Invoke-Start (New-WslRunner)) { exit 0 } else { exit 1 }
}
