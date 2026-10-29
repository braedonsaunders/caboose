<#
.SYNOPSIS
Prepares Windows so phones reach a Caboose host running in WSL directly.

.DESCRIPTION
Switches WSL to mirrored networking, so Linux shares the PC's own network interfaces (the
LAN, Wi-Fi and Tailscale addresses) and a phone connects straight to caboose-host. It
allows the host's TCP port through the Hyper-V firewall that guards WSL, and removes the
netsh portproxy rules that forwarded it into WSL's NAT network: a forwarder holds the
phone's small input messages until WSL acknowledges the previous one, which makes scrolling
and typing arrive in bursts.

Run it in an elevated PowerShell, as the Windows user who runs WSL. It records what it
changed in %ProgramData%\Caboose\wsl-networking.json; -Revert puts that back. WSL applies
networking settings when it starts, so the change takes effect after `wsl --shutdown`
(-Restart does it, which stops every running distribution).

.PARAMETER Port
The TCP ports to publish from WSL: caboose-host's (CABOOSE_PORT, 7310 by default), and any
other WSL service a portproxy rule used to forward.

.PARAMETER Profiles
The firewall profiles the ports are open on: Any (default), or a combination of Domain,
Private and Public.

.PARAMETER Distro
The distribution Caboose runs in, used to confirm the networking mode after -Restart.
Default: WSL's default distribution.

.PARAMETER Restart
Shut WSL down and start the distribution again, so the change applies now.

.PARAMETER Revert
Undo what an earlier run changed.

.EXAMPLE
.\setup-wsl.ps1 -WhatIf
.\setup-wsl.ps1 -Restart
.\setup-wsl.ps1 -Port 7310,8188 -Restart
.\setup-wsl.ps1 -Revert -Restart
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateRange(1, 65535)][int[]]$Port = @(7310),
    [ValidateSet('Any', 'Domain', 'Private', 'Public')][string[]]$Profiles = @('Any'),
    [string]$Distro,
    [switch]$Restart,
    [switch]$Revert
)

Set-StrictMode -Version 3
$ErrorActionPreference = 'Stop'

# WSL's VM creator id in the Hyper-V firewall.
$WslCreator = '{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}'
$StateDir = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'Caboose'
$StatePath = Join-Path $StateDir 'wsl-networking.json'
$WslConfig = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.wslconfig'
# wsl.exe writes UTF-16 unless told otherwise.
$env:WSL_UTF8 = '1'

function Say([string]$Text) { Write-Host "==> $Text" }

function Get-RuleName([int]$Port) { "Caboose-WSL-TCP-$Port" }

function Assert-Ready {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run this in an elevated PowerShell (Run as administrator): the firewall and portproxy need it.'
    }
    $build = [Environment]::OSVersion.Version.Build
    if ($build -lt 22621) {
        throw "Mirrored networking needs Windows 11 22H2 (build 22621) or later; this is build $build."
    }
    $text = (& wsl.exe --version) -join "`n"
    if ($LASTEXITCODE -ne 0 -or $text -notmatch '(\d+)\.(\d+)\.(\d+)') {
        throw 'WSL from the Microsoft Store is required (wsl --install, or wsl --update).'
    }
    if ([int]$Matches[1] -lt 2) {
        throw "Mirrored networking needs WSL 2.0 or later; run wsl --update (found $($Matches[0]))."
    }
    if (-not (Get-Command New-NetFirewallHyperVRule -ErrorAction SilentlyContinue)) {
        throw 'This Windows has no Hyper-V firewall cmdlets; update Windows to use mirrored networking.'
    }
}

# The value of $Key in [$Section] of an INI text, or $null.
function Get-IniValue([string[]]$Lines, [string]$Section, [string]$Key) {
    $inside = $false
    foreach ($line in $Lines) {
        if ($line -match '^\s*\[(.+?)\]\s*$') { $inside = $Matches[1] -eq $Section; continue }
        if ($inside -and $line -match "^\s*$([regex]::Escape($Key))\s*=\s*(.*?)\s*$") { return $Matches[1] }
    }
    return $null
}

# $Lines with $Key set to $Value in [$Section] (or the key removed when $Value is $null),
# every other line kept as it was.
function Set-IniValue([string[]]$Lines, [string]$Section, [string]$Key, $Value) {
    $out = New-Object System.Collections.Generic.List[string]
    $inside = $false; $found = $false; $sectionSeen = $false
    $keyPattern = "^\s*$([regex]::Escape($Key))\s*="
    # A key added to an existing section goes after its last non-blank line.
    $addAtEnd = {
        $at = $out.Count
        while ($at -gt 0 -and $out[$at - 1].Trim() -eq '') { $at-- }
        $out.Insert($at, "$Key=$Value")
    }
    foreach ($line in $Lines) {
        if ($line -match '^\s*\[(.+?)\]\s*$') {
            if ($inside -and -not $found -and $null -ne $Value) { & $addAtEnd; $found = $true }
            $inside = $Matches[1] -eq $Section
            if ($inside) { $sectionSeen = $true }
            $out.Add($line); continue
        }
        if ($inside -and $line -match $keyPattern) {
            if (-not $found -and $null -ne $Value) { $out.Add("$Key=$Value") }
            $found = $true; continue
        }
        $out.Add($line)
    }
    if ($null -ne $Value -and -not $found) {
        if ($sectionSeen) { & $addAtEnd }
        else {
            if ($out.Count -gt 0 -and $out[$out.Count - 1].Trim() -ne '') { $out.Add('') }
            $out.Add("[$Section]")
            $out.Add("$Key=$Value")
        }
    }
    return , $out.ToArray()
}

function Read-Lines([string]$Path) {
    if (Test-Path -LiteralPath $Path) { return , [string[]](Get-Content -LiteralPath $Path) }
    return , [string[]]@()
}

function Write-Lines([string]$Path, [string[]]$Lines) {
    # UTF-8 without a byte order mark, which WSL reads.
    [IO.File]::WriteAllText($Path, (($Lines -join "`r`n") + "`r`n"), (New-Object Text.UTF8Encoding($false)))
}

# The entries of `netsh interface portproxy show v4tov4` output listening on $Port (0: all).
function ConvertFrom-PortProxyTable([string[]]$Lines, [int]$Port) {
    $entries = @()
    foreach ($line in $Lines) {
        if ($line -match '^\s*(\S+)\s+(\d+)\s+(\S+)\s+(\d+)\s*$' -and ($Port -eq 0 -or [int]$Matches[2] -eq $Port)) {
            $entries += [pscustomobject]@{ ListenAddress = $Matches[1]; ListenPort = [int]$Matches[2]; ConnectAddress = $Matches[3]; ConnectPort = [int]$Matches[4] }
        }
    }
    return , $entries
}

function Get-PortProxies([int]$Port) { return , (ConvertFrom-PortProxyTable (& netsh.exe interface portproxy show v4tov4) $Port) }

function Get-NetworkingMode {
    $arguments = @()
    if ($Distro) { $arguments += @('-d', $Distro) }
    # Read all of it: stopping a native pipeline early (Select-Object -First) kills wsl.exe.
    $output = @(& wsl.exe @arguments --exec wslinfo --networking-mode 2>$null)
    if ($LASTEXITCODE -ne 0 -or $output.Count -eq 0) { return 'unknown' }
    return "$($output[0])".Trim()
}

function Restart-Wsl {
    if (-not $PSCmdlet.ShouldProcess('every running WSL distribution', 'wsl --shutdown and start again')) { return }
    Say 'Restarting WSL'
    & wsl.exe --shutdown
    if ($LASTEXITCODE -ne 0) { throw 'wsl --shutdown failed' }
    Say "WSL networking is now: $(Get-NetworkingMode)"
}

function Invoke-Apply {
    Assert-Ready
    $lines = Read-Lines $WslConfig
    $previousMode = Get-IniValue $lines 'wsl2' 'networkingMode'
    $state = $null
    if (Test-Path -LiteralPath $StatePath) { $state = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json }
    $created = @(); $removed = @()

    if ($PSCmdlet.ShouldProcess($WslConfig, 'set [wsl2] networkingMode=mirrored')) {
        if ($previousMode -ne 'mirrored') {
            Say "Setting networkingMode=mirrored in $WslConfig"
            Write-Lines $WslConfig (Set-IniValue $lines 'wsl2' 'networkingMode' 'mirrored')
        } else { Say "$WslConfig already uses mirrored networking" }
    }

    foreach ($p in $Port) {
        $name = Get-RuleName $p
        if ($PSCmdlet.ShouldProcess("Hyper-V firewall (WSL), TCP $p inbound", 'allow')) {
            if (Get-NetFirewallHyperVRule -Name $name -ErrorAction SilentlyContinue) {
                Set-NetFirewallHyperVRule -Name $name -Enabled True -Action Allow -Profiles $Profiles | Out-Null
            } else {
                New-NetFirewallHyperVRule -Name $name -DisplayName "WSL inbound TCP $p (Caboose)" -Direction Inbound `
                    -VMCreatorId $WslCreator -Protocol TCP -LocalPorts $p -Action Allow -Profiles $Profiles | Out-Null
                $created += $p
            }
            Say "Allowed TCP $p into WSL through the Hyper-V firewall ($($Profiles -join ', '))"
        }
        foreach ($proxy in (Get-PortProxies $p)) {
            if ($PSCmdlet.ShouldProcess("portproxy $($proxy.ListenAddress):$p -> $($proxy.ConnectAddress):$($proxy.ConnectPort)", 'delete')) {
                & netsh.exe interface portproxy delete v4tov4 listenport=$p listenaddress=$($proxy.ListenAddress) | Out-Null
                if ($LASTEXITCODE -ne 0) { throw "could not delete the portproxy on $($proxy.ListenAddress):$p" }
                $removed += $proxy
                Say "Removed the portproxy $($proxy.ListenAddress):$p -> $($proxy.ConnectAddress):$($proxy.ConnectPort)"
            }
        }
    }

    if (-not $WhatIfPreference) {
        # The first run records what was there before, so -Revert restores the original.
        if ($null -eq $state) {
            $state = [pscustomobject]@{ wslConfig = $WslConfig; networkingMode = $previousMode; rulesCreated = @(); portProxies = @() }
        }
        $state.rulesCreated = @(@($state.rulesCreated) + $created | Sort-Object -Unique)
        $state.portProxies = @(@($state.portProxies) + $removed)
        New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
        $state | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $StatePath -Encoding UTF8
    }

    $all = ConvertFrom-PortProxyTable (& netsh.exe interface portproxy show v4tov4) 0
    $others = @($all | Where-Object { $Port -notcontains $_.ListenPort })
    if ($others) {
        $list = ($others | ForEach-Object { "  $($_.ListenAddress):$($_.ListenPort) -> $($_.ConnectAddress):$($_.ConnectPort)" }) -join "`n"
        Write-Warning "Other portproxy rules remain. With mirrored networking WSL has no NAT address: a rule that forwards into it, or listens on it, stops working. A WSL service is reached on the PC's own addresses instead; pass its port to -Port to publish it:`n$list"
    }
    if ($Restart) { Restart-Wsl }
    elseif (-not $WhatIfPreference) { Say 'Done. Run wsl --shutdown (or this script with -Restart) for WSL to start with mirrored networking.' }
}

function Invoke-Revert {
    if (-not (Test-Path -LiteralPath $StatePath)) { throw "Nothing to revert: $StatePath does not exist." }
    $state = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
    if ($PSCmdlet.ShouldProcess($state.wslConfig, "restore networkingMode ($(if ($state.networkingMode) { $state.networkingMode } else { 'the default' }))")) {
        Write-Lines $state.wslConfig (Set-IniValue (Read-Lines $state.wslConfig) 'wsl2' 'networkingMode' $state.networkingMode)
        Say "Restored networkingMode in $($state.wslConfig)"
    }
    foreach ($p in @($state.rulesCreated)) {
        if ($PSCmdlet.ShouldProcess("Hyper-V firewall rule $(Get-RuleName $p)", 'remove')) {
            Remove-NetFirewallHyperVRule -Name (Get-RuleName $p) -ErrorAction SilentlyContinue
            Say "Removed the Hyper-V firewall rule for TCP $p"
        }
    }
    foreach ($proxy in @($state.portProxies)) {
        if ($PSCmdlet.ShouldProcess("portproxy $($proxy.ListenAddress):$($proxy.ListenPort) -> $($proxy.ConnectAddress):$($proxy.ConnectPort)", 'add')) {
            & netsh.exe interface portproxy add v4tov4 listenport=$($proxy.ListenPort) listenaddress=$($proxy.ListenAddress) connectport=$($proxy.ConnectPort) connectaddress=$($proxy.ConnectAddress) | Out-Null
            Say "Restored the portproxy $($proxy.ListenAddress):$($proxy.ListenPort) -> $($proxy.ConnectAddress):$($proxy.ConnectPort)"
        }
    }
    if (-not $WhatIfPreference) { Remove-Item -LiteralPath $StatePath }
    if ($Restart) { Restart-Wsl }
    elseif (-not $WhatIfPreference) { Say 'Reverted. Run wsl --shutdown for WSL to start with its previous networking. WSL may give Linux a new NAT address, which restored portproxy rules do not follow.' }
}

# Dot-sourcing (`. .\setup-wsl.ps1`) only defines the functions, for setup-wsl.tests.ps1.
if ($MyInvocation.InvocationName -ne '.') {
    if ($Revert) { Invoke-Revert } else { Invoke-Apply }
}
