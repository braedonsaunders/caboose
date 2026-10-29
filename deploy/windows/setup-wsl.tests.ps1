# Unit tests for setup-wsl.ps1's logic: editing .wslconfig, reading netsh's portproxy
# table, and applying and reverting against a machine in memory, including runs that are
# interrupted part way. They need no administrator, WSL or network, so they run anywhere
# PowerShell does (Windows PowerShell 5.1 or pwsh on macOS and Linux):
#
#   pwsh -NoProfile -File deploy/windows/setup-wsl.tests.ps1
. (Join-Path $PSScriptRoot 'setup-wsl.ps1')

$failures = 0
function Check([string]$Name, [scriptblock]$Body) {
    try { & $Body; Write-Host "ok: $Name" }
    catch { $script:failures++; Write-Host "FAIL: $Name - $($_.Exception.Message)" }
}
function Same($Actual, $Expected) {
    $a = $Actual -join "`n"; $e = $Expected -join "`n"
    if ($a -ne $e) { throw "expected`n$e`ngot`n$a" }
}

Check 'adds the key to an existing [wsl2] section, keeping every other line' {
    $lines = @('[wsl2]', 'swapFile=D:\\WSL\\swap.vhdx', 'memory=16GB', '', '[experimental]', 'sparseVhd=true')
    Same (Set-IniValue $lines 'wsl2' 'networkingMode' 'mirrored') @('[wsl2]', 'swapFile=D:\\WSL\\swap.vhdx', 'memory=16GB', 'networkingMode=mirrored', '', '[experimental]', 'sparseVhd=true')
}

Check 'adds the key to a [wsl2] section that ends the file' {
    Same (Set-IniValue @('[wsl2]', 'memory=16GB', '', '') 'wsl2' 'networkingMode' 'mirrored') @('[wsl2]', 'memory=16GB', 'networkingMode=mirrored', '', '')
}

Check 'replaces the key in place, whatever its case and spacing' {
    Same (Set-IniValue @('[wsl2]', 'memory=8GB', ' NetworkingMode = nat', 'swap=0') 'wsl2' 'networkingMode' 'mirrored') @('[wsl2]', 'memory=8GB', 'networkingMode=mirrored', 'swap=0')
}

Check 'the key in another section is not the one changed' {
    Same (Set-IniValue @('[experimental]', 'networkingMode=nat') 'wsl2' 'networkingMode' 'mirrored') @('[experimental]', 'networkingMode=nat', '', '[wsl2]', 'networkingMode=mirrored')
}

Check 'creates the file contents when there is none' {
    Same (Set-IniValue @() 'wsl2' 'networkingMode' 'mirrored') @('[wsl2]', 'networkingMode=mirrored')
}

Check 'a null value removes the key (revert to the default)' {
    Same (Set-IniValue @('[wsl2]', 'memory=8GB', 'networkingMode=mirrored') 'wsl2' 'networkingMode' $null) @('[wsl2]', 'memory=8GB')
}

Check 'duplicate keys collapse to one' {
    Same (Set-IniValue @('[wsl2]', 'networkingMode=nat', 'networkingMode=nat') 'wsl2' 'networkingMode' 'mirrored') @('[wsl2]', 'networkingMode=mirrored')
}

Check 'reads a value from its own section only' {
    $lines = @('[experimental]', 'networkingMode=virtioproxy', '[wsl2]', 'networkingmode = nat ')
    Same (Get-IniValue $lines 'wsl2' 'networkingMode') 'nat'
    if ($null -ne (Get-IniValue @('[wsl2]', 'memory=8GB') 'wsl2' 'networkingMode')) { throw 'expected no value' }
}

Check 'reads the portproxy entries on one port from netsh output' {
    $table = @(
        '', 'Listen on ipv4:             Connect to ipv4:', '',
        'Address         Port        Address         Port',
        '--------------- ----------  --------------- ----------',
        '0.0.0.0         7860        172.17.14.151   7860',
        '0.0.0.0         7310        172.17.14.151   7310',
        '192.168.1.5     7310        172.17.14.151   7311', '')
    $entries = ConvertFrom-PortProxyTable $table 7310
    Same ($entries | ForEach-Object { "$($_.ListenAddress):$($_.ListenPort)>$($_.ConnectAddress):$($_.ConnectPort)" }) @('0.0.0.0:7310>172.17.14.151:7310', '192.168.1.5:7310>172.17.14.151:7311')
    if ((ConvertFrom-PortProxyTable $table 9999).Count -ne 0) { throw 'expected no entries on 9999' }
    if ((ConvertFrom-PortProxyTable $table 0).Count -ne 3) { throw 'port 0 should list every entry' }
}

Check 'an atomic write creates and then replaces a file, leaving no temporary' {
    $path = Join-Path ([IO.Path]::GetTempPath()) "caboose-atomic-$PID.txt"
    try {
        Write-FileAtomic $path 'one'
        Write-FileAtomic $path 'two'
        Same ([IO.File]::ReadAllText($path)) 'two'
        if (Test-Path -LiteralPath "$path.tmp") { throw 'the temporary file remains' }
    } finally { Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue }
}

# A machine in memory: .wslconfig, Hyper-V firewall rules, portproxy rules and the state
# file (kept as JSON text, as on disk). $script:failAt makes the Nth change throw, the way
# a crash or a failing netsh would interrupt a run.
$script:machine = $null
$script:failAt = 0
$script:changes = 0
function New-Machine([string[]]$Config, $Rules = @{}, $Proxies = @()) {
    $script:machine = @{ config = $Config; rules = $Rules; proxies = @($Proxies); state = $null }
    $script:failAt = 0; $script:changes = 0
}
function Change { $script:changes++; if ($script:failAt -gt 0 -and $script:changes -eq $script:failAt) { throw "interrupted at change $($script:changes)" } }
# portproxy rules have no order, so they compare as a set.
function Snapshot { @{ config = $script:machine.config; rules = $script:machine.rules; proxies = @($script:machine.proxies | Sort-Object listenPort, listenAddress) } | ConvertTo-Json -Depth 5 -Compress }
function Proxy([string]$Listen, [int]$Port, [string]$Connect) { [pscustomobject]@{ listenAddress = $Listen; listenPort = $Port; connectAddress = $Connect; connectPort = $Port } }
$fake = @{
    ReadConfig   = { param($Path) if ($null -eq $script:machine.config) { , [string[]]@() } else { , [string[]]$script:machine.config } }
    ConfigExists = { param($Path) $null -ne $script:machine.config }
    WriteConfig  = { param($Path, $Lines) Change; $script:machine.config = [string[]]$Lines }
    RemoveConfig = { param($Path) Change; $script:machine.config = $null }
    GetRule      = { param($Name) $r = $script:machine.rules[$Name]; if ($r) { [pscustomobject]@{ enabled = $r.enabled; action = $r.action; profiles = $r.profiles } } }
    NewRule      = { param($Name, $Port, $Profiles) Change; $script:machine.rules[$Name] = @{ enabled = 'True'; action = 'Allow'; profiles = ($Profiles -join ', ') } }
    SetRule      = { param($Name, $Enabled, $Action, $Profiles) Change; $script:machine.rules[$Name] = @{ enabled = $Enabled; action = $Action; profiles = ($Profiles -join ', ') } }
    RemoveRule   = { param($Name) Change; $script:machine.rules.Remove($Name) }
    GetProxies   = { param($Port) $script:machine.proxies | Where-Object { $Port -eq 0 -or $_.listenPort -eq $Port } }
    DeleteProxy  = { param($Proxy) Change; $script:machine.proxies = @($script:machine.proxies | Where-Object { -not (Test-SameProxy $_ $Proxy) }) }
    AddProxy     = { param($Proxy) Change; $script:machine.proxies = @($script:machine.proxies) + $Proxy }
    LoadState    = { if ($script:machine.state) { $script:machine.state | ConvertFrom-Json } }
    SaveState    = { param($State) $script:machine.state = $State | ConvertTo-Json -Depth 5 }
    ClearState   = { $script:machine.state = $null }
}
function Quietly([scriptblock]$Body) { & $Body 3>$null 6>$null | Out-Null }
function Apply { Quietly { Invoke-Apply $fake 'C:\Users\o\.wslconfig' @(7310) @('Any') } }
function Revert { Quietly { Invoke-Revert $fake } }
function Interrupted([scriptblock]$Body, [int]$At) {
    $script:changes = 0; $script:failAt = $At
    $threw = $false
    try { & $Body } catch { $threw = $true }
    $script:failAt = 0; $script:changes = 0
    if (-not $threw) { throw "change $At did not happen" }
}
function Original {
    New-Machine @('[wsl2]', 'memory=16GB') @{} @((Proxy '0.0.0.0' 7310 '172.17.14.151'), (Proxy '192.168.68.85' 7310 '172.17.14.151'), (Proxy '0.0.0.0' 8188 '172.17.14.151'))
}

Check 'apply then revert leaves the machine as it was' {
    Original; $before = Snapshot
    Apply
    Same (Get-IniValue $script:machine.config 'wsl2' 'networkingMode') 'mirrored'
    Same $script:machine.rules['Caboose-WSL-TCP-7310'].action 'Allow'
    Same @($script:machine.proxies).Count 1
    Revert
    Same (Snapshot) $before
    if ($script:machine.state) { throw 'the state file remains' }
}

Check 'applying twice records the first original, not mirrored' {
    Original; $before = Snapshot
    Apply; Apply; Revert
    Same (Snapshot) $before
}

foreach ($case in @(@{ at = 1; what = 'writing .wslconfig' }, @{ at = 2; what = 'creating the firewall rule' }, @{ at = 3; what = 'deleting the first portproxy' }, @{ at = 4; what = 'deleting the second portproxy' })) {
    Check "an apply interrupted at $($case.what) reverts to the original" {
        Original; $before = Snapshot
        Interrupted { Apply } $case.at
        Revert
        Same (Snapshot) $before
    }
    Check "an apply interrupted at $($case.what) can be run again, then reverted" {
        Original; $before = Snapshot
        Interrupted { Apply } $case.at
        Apply
        Same @($script:machine.proxies).Count 1
        Revert
        Same (Snapshot) $before
    }
}

Check 'a rule that already existed is restored to its own values, not removed' {
    New-Machine @('[wsl2]') @{ 'Caboose-WSL-TCP-7310' = @{ enabled = 'False'; action = 'Block'; profiles = 'Private, Public' } } @()
    $before = Snapshot
    Apply
    Same $script:machine.rules['Caboose-WSL-TCP-7310'].enabled 'True'
    Same $script:machine.rules['Caboose-WSL-TCP-7310'].action 'Allow'
    Revert
    Same (Snapshot) $before
}

Check 'an interrupted revert continues where it stopped' {
    Original; $before = Snapshot
    Apply
    Interrupted { Revert } 3
    if (-not $script:machine.state) { throw 'the state was dropped before the revert finished' }
    Revert
    Same (Snapshot) $before
    if ($script:machine.state) { throw 'the state file remains' }
}

Check 'a .wslconfig the script created is removed on revert' {
    New-Machine $null @{} @()
    Apply
    if ($null -eq $script:machine.config) { throw 'no .wslconfig was written' }
    Revert
    if ($null -ne $script:machine.config) { throw '.wslconfig remains' }
}

Check 'revert with nothing applied refuses' {
    New-Machine @('[wsl2]') @{} @()
    $threw = $false
    try { Revert } catch { $threw = $true }
    if (-not $threw) { throw 'expected an error' }
}

if ($failures -gt 0) { Write-Host "$failures failed"; exit 1 }
Write-Host 'all passed'
