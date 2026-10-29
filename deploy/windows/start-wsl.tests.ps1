# Unit tests for start-wsl.ps1: the order of its steps, and what it refuses to do, against a
# runner that records calls instead of running wsl.exe. No WSL or administrator needed:
#
#   pwsh -NoProfile -File deploy/windows/start-wsl.tests.ps1
. (Join-Path $PSScriptRoot 'start-wsl.ps1')

$failures = 0
function Check([string]$Name, [scriptblock]$Body) {
    try { & $Body; Write-Host "ok: $Name" }
    catch { $script:failures++; Write-Host "FAIL: $Name - $($_.Exception.Message)" }
}
function Same($Actual, $Expected) {
    $a = $Actual -join "`n"; $e = $Expected -join "`n"
    if ($a -ne $e) { throw "expected`n$e`ngot`n$a" }
}

# A fake WSL: $script:world says what each call answers, $script:calls records them in order.
function New-World { $script:calls = New-Object System.Collections.Generic.List[string]; $script:world = @{ attach = @(@{ ok = $true; output = '' }); task = 'Ready'; running = $true; mountOk = $true; source = '/dev/sde 6d0eb1d8-c917-4b5d-a9b1-e596614cc6d4'; service = 'active' } }
$fake = @{
    Ready     = { $true }
    Attach    = { param($Path) $script:calls.Add("attach $Path"); $r = $script:world.attach[0]; if ($script:world.attach.Count -gt 1) { $script:world.attach = $script:world.attach[1..($script:world.attach.Count - 1)] }; $r }
    Running   = { $script:world.running }
    TaskState = { param($Name) $script:world.task }
    StartTask = { param($Name) $script:calls.Add("start-task $Name"); $script:world.task = 'Running' }
    Shell     = { param($Command)
        if ($Command -match '^mountpoint') { $script:calls.Add('mount'); return @{ ok = $script:world.mountOk; output = $script:world.source } }
        $script:calls.Add("service $(($Command -split ' ')[3])"); @{ ok = $true; output = $script:world.service } }
    KeepAlive = { $script:calls.Add('keepalive') }
    Sleep     = { param($Seconds) }
}
function Setup([string[]]$Disks, [string]$Task, [string]$Mount, [string[]]$Units, [string]$FsUuid = '') {
    $script:Vhd = $Disks; $script:KeepaliveTask = $Task; $script:MountPoint = $Mount; $script:Service = $Units; $script:Uuid = $FsUuid
    $script:Log = $null; $script:WaitSeconds = 5
    New-World
}
function Run { $script:result = Invoke-Start $fake 6>$null }

Check 'attaches the disk before starting the keepalive, then mounts, then starts services in order' {
    Setup @('I:\c.vhdx') 'Keepalive' '/home/o/disks' @('docker', 'caboose-host')
    Run
    Same $script:calls @('attach I:\c.vhdx', 'start-task Keepalive', 'mount', "service 'docker'", "service 'caboose-host'")
    if (-not $script:result) { throw 'expected success' }
}

Check 'a disk that is already attached is not retried' {
    Setup @('I:\c.vhdx') 'Keepalive' '/home/o/disks' @('caboose-host')
    $script:world.attach = @(@{ ok = $false; output = 'Error code: Wsl/Service/AttachDisk/WSL_E_DISK_ALREADY_ATTACHED' })
    Run
    Same @($script:calls | Where-Object { $_ -like 'attach*' }).Count 1
    if (-not $script:result) { throw 'expected success' }
}

Check 'a disk that cannot be attached is tried three times, then nothing else runs' {
    Setup @('I:\c.vhdx') 'Keepalive' '/home/o/disks' @('caboose-host')
    $script:world.attach = @(@{ ok = $false; output = 'The system cannot find the file specified.' })
    Run
    Same $script:calls @('attach I:\c.vhdx', 'attach I:\c.vhdx', 'attach I:\c.vhdx')
    if ($script:result) { throw 'expected failure' }
}

Check 'a mount command that fails blocks the services, and the own keepalive does not start' {
    Setup @() $null '/home/o/disks' @('caboose-host')
    $script:world.mountOk = $false; $script:world.source = 'mount: /home/o/disks: can''t find UUID=6d0eb1d8'
    Run
    Same $script:calls @('mount')
    if ($script:result) { throw 'expected failure' }
}

Check 'a disk with another file system UUID blocks the services' {
    Setup @() 'Keepalive' '/home/o/disks' @('caboose-host') '6d0eb1d8-c917-4b5d-a9b1-e596614cc6d4'
    $script:world.source = '/dev/sdf 11111111-2222-3333-4444-555555555555'
    Run
    if (@($script:calls | Where-Object { $_ -like 'service*' })) { throw 'a service was started on the wrong disk' }
    if ($script:result) { throw 'expected failure' }
}

Check 'the expected file system UUID passes' {
    Setup @() 'Keepalive' '/home/o/disks' @('caboose-host') '6d0eb1d8-c917-4b5d-a9b1-e596614cc6d4'
    Run
    if (-not $script:result) { throw 'expected success' }
}

Check 'a file system mounted from a loop device (an image file) blocks the services' {
    Setup @() 'Keepalive' '/home/o/disks' @('caboose-host')
    $script:world.source = '/dev/loop3 6d0eb1d8-c917-4b5d-a9b1-e596614cc6d4'
    Run
    if (@($script:calls | Where-Object { $_ -like 'service*' })) { throw 'a service was started on a loop mount' }
    if ($script:result) { throw 'expected failure' }
}

Check 'a keepalive that is already running is not started again' {
    Setup @() 'Keepalive' $null @('caboose-host')
    $script:world.task = 'Running'
    Run
    Same $script:calls @("service 'caboose-host'")
}

Check 'without a keepalive task it keeps the distribution running itself, last' {
    Setup @() $null '/home/o/disks' @('caboose-host')
    Run
    Same $script:calls @('mount', "service 'caboose-host'", 'keepalive')
}

Check 'a service that does not come up is reported' {
    Setup @() 'Keepalive' $null @('caboose-host')
    $script:world.service = 'failed'
    Run
    if ($script:result) { throw 'expected failure' }
}

Check 'disk sources' {
    foreach ($ok in '/dev/sde', '/dev/sdab1', '/dev/vdb', '/dev/nvme0n1p2') { if (-not (Test-BlockSource $ok)) { throw "$ok should be a disk" } }
    foreach ($no in '/dev/loop0', '', 'tmpfs', '/home/o/disks.xfs.img', '/dev/mapper/x') { if (Test-BlockSource $no) { throw "$no should not be a disk" } }
}

Check 'already-attached messages' {
    if (-not (Test-AlreadyAttached 'Wsl/Service/AttachDisk/WSL_E_DISK_ALREADY_ATTACHED')) { throw 'missed the error code' }
    if (Test-AlreadyAttached 'The system cannot find the file specified.') { throw 'false positive' }
}

Check 'Windows arguments round-trip through a real child process' {
    $script = Join-Path ([IO.Path]::GetTempPath()) "caboose-args-$PID.ps1"
    Set-Content -LiteralPath $script -Value '$args -join "|"'
    try {
        $shell = (Get-Process -Id $PID).Path
        $words = @('plain', 'two words', 'say "hi"', 'C:\dir with space\', "it's")
        $result = Invoke-Native $shell (@('-NoProfile', '-File', $script) + $words) 30
        if (-not $result.ok) { throw $result.output }
        Same $result.output ($words -join '|')
    } finally { Remove-Item -LiteralPath $script -ErrorAction SilentlyContinue }
}

Check 'a native call that hangs is killed at its timeout' {
    $shell = (Get-Process -Id $PID).Path
    $started = Get-Date
    $result = Invoke-Native $shell @('-NoProfile', '-Command', 'Start-Sleep 20') 2
    if ($result.ok -or $result.output -notmatch 'timed out') { throw "expected a timeout, got $($result.output)" }
    if (((Get-Date) - $started).TotalSeconds -gt 10) { throw 'the timeout did not stop the wait' }
}

Check 'shell words are quoted' {
    Same (ConvertTo-ShWord "/home/o/it's") "'/home/o/it'\''s'"
}

if ($failures -gt 0) { Write-Host "$failures failed"; exit 1 }
Write-Host 'all passed'
