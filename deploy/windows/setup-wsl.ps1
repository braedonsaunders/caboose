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

Run it in an elevated PowerShell, as the Windows user who runs WSL. Before each change it
records the original in %ProgramData%\Caboose\wsl-networking.json, so -Revert restores it
even after an interrupted run, and either can be run again to finish. WSL applies
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
Undo what earlier runs changed.

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
$StatePath = Join-Path (Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'Caboose') 'wsl-networking.json'
$WslConfig = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.wslconfig'
# wsl.exe writes UTF-16 unless told otherwise.
$env:WSL_UTF8 = '1'

# Under -WhatIf the What if: lines say what would happen instead.
function Say([string]$Text) { if (-not $WhatIfPreference) { Write-Host "==> $Text" } }

function Get-RuleName([int]$Port) { "Caboose-WSL-TCP-$Port" }

function Format-Proxy($Proxy) { "$($Proxy.listenAddress):$($Proxy.listenPort) -> $($Proxy.connectAddress):$($Proxy.connectPort)" }

function Assert-Ready {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run this in an elevated PowerShell (Run as administrator): the firewall and portproxy need it.'
    }
    $build = [Environment]::OSVersion.Version.Build
    if ($build -lt 22621) {
        throw "Mirrored networking needs Windows 11 22H2 (build 22621) or later; this is build $build. Keep a forwarder into WSL's NAT network, or update Windows."
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

# The entries of `netsh interface portproxy show v4tov4` output listening on $Port (0: all).
function ConvertFrom-PortProxyTable([string[]]$Lines, [int]$Port) {
    $entries = @()
    foreach ($line in $Lines) {
        if ($line -match '^\s*(\S+)\s+(\d+)\s+(\S+)\s+(\d+)\s*$' -and ($Port -eq 0 -or [int]$Matches[2] -eq $Port)) {
            $entries += [pscustomobject]@{ listenAddress = $Matches[1]; listenPort = [int]$Matches[2]; connectAddress = $Matches[3]; connectPort = [int]$Matches[4] }
        }
    }
    return , $entries
}

function Read-Lines([string]$Path) {
    if (Test-Path -LiteralPath $Path) { return , [string[]](Get-Content -LiteralPath $Path) }
    return , [string[]]@()
}

# Written to a temporary file and moved over the original, so a crash leaves one or the other.
function Write-FileAtomic([string]$Path, [string]$Text) {
    $directory = Split-Path -Parent $Path
    if ($directory -and -not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Force -Path $directory | Out-Null }
    $temporary = "$Path.tmp"
    # UTF-8 without a byte order mark, which WSL reads.
    [IO.File]::WriteAllText($temporary, $Text, (New-Object Text.UTF8Encoding($false)))
    if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($temporary, $Path, $null) } else { [IO.File]::Move($temporary, $Path) }
}

# Everything the script reads and changes on the machine. Tests substitute their own.
function New-WindowsSystem {
    @{
        ReadConfig   = { param($Path) Read-Lines $Path }
        WriteConfig  = { param($Path, $Lines) Write-FileAtomic $Path (($Lines -join "`r`n") + "`r`n") }
        RemoveConfig = { param($Path) Remove-Item -LiteralPath $Path }
        ConfigExists = { param($Path) Test-Path -LiteralPath $Path }
        GetRule      = { param($Name)
            $rule = Get-NetFirewallHyperVRule -Name $Name -ErrorAction SilentlyContinue
            if ($rule) { [pscustomobject]@{ enabled = "$($rule.Enabled)"; action = "$($rule.Action)"; profiles = "$($rule.Profiles)" } }
        }
        NewRule      = { param($Name, $Port, $Profiles)
            New-NetFirewallHyperVRule -Name $Name -DisplayName "WSL inbound TCP $Port (Caboose)" -Direction Inbound `
                -VMCreatorId $WslCreator -Protocol TCP -LocalPorts $Port -Action Allow -Profiles $Profiles | Out-Null
        }
        SetRule      = { param($Name, $Enabled, $Action, $Profiles)
            Set-NetFirewallHyperVRule -Name $Name -Enabled $Enabled -Action $Action -Profiles $Profiles | Out-Null
        }
        RemoveRule   = { param($Name) Remove-NetFirewallHyperVRule -Name $Name }
        # One entry per output item (callers collect them with @()).
        GetProxies   = { param($Port) $entries = ConvertFrom-PortProxyTable (& netsh.exe interface portproxy show v4tov4) $Port; $entries }
        DeleteProxy  = { param($Proxy)
            & netsh.exe interface portproxy delete v4tov4 listenport=$($Proxy.listenPort) listenaddress=$($Proxy.listenAddress) | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "could not delete the portproxy $(Format-Proxy $Proxy)" }
        }
        AddProxy     = { param($Proxy)
            & netsh.exe interface portproxy add v4tov4 listenport=$($Proxy.listenPort) listenaddress=$($Proxy.listenAddress) connectport=$($Proxy.connectPort) connectaddress=$($Proxy.connectAddress) | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "could not add the portproxy $(Format-Proxy $Proxy)" }
        }
        LoadState    = { if (Test-Path -LiteralPath $StatePath) { Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json } }
        SaveState    = { param($State) Write-FileAtomic $StatePath ($State | ConvertTo-Json -Depth 5) }
        ClearState   = { if (Test-Path -LiteralPath $StatePath) { Remove-Item -LiteralPath $StatePath } }
    }
}

# The same machine under -WhatIf: reads are real, changes are printed.
function New-WhatIfSystem($Real) {
    $dry = @{}
    foreach ($read in 'ReadConfig', 'ConfigExists', 'GetRule', 'GetProxies', 'LoadState') { $dry[$read] = $Real[$read] }
    $dry.WriteConfig = { param($Path, $Lines) Write-Host "What if: set [wsl2] networkingMode in $Path" }
    $dry.RemoveConfig = { param($Path) Write-Host "What if: remove $Path" }
    $dry.NewRule = { param($Name, $Port, $Profiles) Write-Host "What if: allow TCP $Port into WSL through the Hyper-V firewall ($($Profiles -join ', '))" }
    $dry.SetRule = { param($Name, $Enabled, $Action, $Profiles) Write-Host "What if: set Hyper-V firewall rule $Name to Enabled=$Enabled Action=$Action Profiles=$($Profiles -join ', ')" }
    $dry.RemoveRule = { param($Name) Write-Host "What if: remove Hyper-V firewall rule $Name" }
    $dry.DeleteProxy = { param($Proxy) Write-Host "What if: delete portproxy $(Format-Proxy $Proxy)" }
    $dry.AddProxy = { param($Proxy) Write-Host "What if: add portproxy $(Format-Proxy $Proxy)" }
    $dry.SaveState = { param($State) }
    $dry.ClearState = { }
    return $dry
}

function New-State([string]$ConfigPath) {
    [pscustomobject]@{ version = 1; wslConfig = $ConfigPath; config = $null; rules = @(); proxies = @() }
}

function Test-SameProxy($A, $B) { $A.listenAddress -eq $B.listenAddress -and [int]$A.listenPort -eq [int]$B.listenPort }

# Applies mirrored networking. Each original is saved to the state before it is changed,
# and a value already in the state (from an earlier or interrupted run) is kept, so the
# state always describes the machine before the first run.
function Invoke-Apply($System, [string]$ConfigPath, [int[]]$Ports, [string[]]$Profiles) {
    $state = & $System.LoadState
    if ($null -eq $state) { $state = New-State $ConfigPath }
    $lines = & $System.ReadConfig $ConfigPath
    $mode = Get-IniValue $lines 'wsl2' 'networkingMode'

    if ($mode -ne 'mirrored') {
        if ($null -eq $state.config) {
            $state.config = [pscustomobject]@{ existed = [bool](& $System.ConfigExists $ConfigPath); networkingMode = $mode }
            & $System.SaveState $state
        }
        & $System.WriteConfig $ConfigPath (Set-IniValue $lines 'wsl2' 'networkingMode' 'mirrored')
        Say "Set networkingMode=mirrored in $ConfigPath"
    } else { Say "$ConfigPath already uses mirrored networking" }

    foreach ($p in $Ports) {
        $name = Get-RuleName $p
        $current = & $System.GetRule $name
        if (-not @($state.rules | Where-Object { [int]$_.port -eq $p })) {
            $original = [pscustomobject]@{ port = $p; existed = $null -ne $current; enabled = $null; action = $null; profiles = $null }
            if ($current) { $original.enabled = $current.enabled; $original.action = $current.action; $original.profiles = $current.profiles }
            $state.rules = @($state.rules) + $original
            & $System.SaveState $state
        }
        if ($current) { & $System.SetRule $name 'True' 'Allow' $Profiles } else { & $System.NewRule $name $p $Profiles }
        Say "Allowed TCP $p into WSL through the Hyper-V firewall ($($Profiles -join ', '))"

        foreach ($proxy in @(& $System.GetProxies $p)) {
            if (-not @($state.proxies | Where-Object { Test-SameProxy $_ $proxy })) {
                $state.proxies = @($state.proxies) + $proxy
                & $System.SaveState $state
            }
            & $System.DeleteProxy $proxy
            Say "Removed the portproxy $(Format-Proxy $proxy)"
        }
    }

    $others = @(& $System.GetProxies 0 | Where-Object { $Ports -notcontains [int]$_.listenPort })
    if ($others) {
        $list = ($others | ForEach-Object { "  $(Format-Proxy $_)" }) -join "`n"
        Write-Warning "Other portproxy rules remain. With mirrored networking WSL has no NAT address: a rule that forwards into it, or listens on it, stops working. A WSL service is reached on the PC's own addresses instead; pass its port to -Port to publish it:`n$list"
    }
}

# Restores the originals one at a time, removing each from the state once it is back, so an
# interrupted revert continues where it stopped.
function Invoke-Revert($System) {
    $state = & $System.LoadState
    if ($null -eq $state) { throw "Nothing to revert: $StatePath does not exist." }
    $path = $state.wslConfig

    if ($null -ne $state.config) {
        $lines = Set-IniValue (& $System.ReadConfig $path) 'wsl2' 'networkingMode' $state.config.networkingMode
        $left = @($lines | Where-Object { $_.Trim() -ne '' })
        if (-not $state.config.existed -and ($left.Count -eq 0 -or ($left.Count -eq 1 -and $left[0].Trim() -eq '[wsl2]'))) {
            if (& $System.ConfigExists $path) { & $System.RemoveConfig $path }
            Say "Removed $path, which this script created"
        } else {
            & $System.WriteConfig $path $lines
            Say "Restored networkingMode in $path ($(if ($state.config.networkingMode) { $state.config.networkingMode } else { 'unset' }))"
        }
        $state.config = $null
        & $System.SaveState $state
    }

    foreach ($rule in @($state.rules)) {
        $name = Get-RuleName $rule.port
        if ($rule.existed) {
            & $System.SetRule $name $rule.enabled $rule.action ($rule.profiles -split ',\s*')
            Say "Restored the Hyper-V firewall rule $name"
        } elseif (& $System.GetRule $name) {
            & $System.RemoveRule $name
            Say "Removed the Hyper-V firewall rule $name"
        }
        $state.rules = @($state.rules | Where-Object { [int]$_.port -ne [int]$rule.port })
        & $System.SaveState $state
    }

    foreach ($proxy in @($state.proxies)) {
        if (-not @(& $System.GetProxies ([int]$proxy.listenPort) | Where-Object { Test-SameProxy $_ $proxy })) {
            & $System.AddProxy $proxy
            Say "Restored the portproxy $(Format-Proxy $proxy)"
        }
        $state.proxies = @($state.proxies | Where-Object { -not (Test-SameProxy $_ $proxy) })
        & $System.SaveState $state
    }

    & $System.ClearState
}

function Get-NetworkingMode {
    $arguments = @()
    if ($Distro) { $arguments += @('-d', $Distro) }
    # Read all of it: stopping a native pipeline early (Select-Object -First) kills wsl.exe.
    $output = @(& wsl.exe @arguments --exec wslinfo --networking-mode 2>$null)
    if ($LASTEXITCODE -ne 0 -or $output.Count -eq 0) { return 'unknown' }
    return "$($output[0])".Trim()
}

function Restart-Wsl {
    Say 'Restarting WSL'
    & wsl.exe --shutdown
    if ($LASTEXITCODE -ne 0) { throw 'wsl --shutdown failed' }
    Say "WSL networking is now: $(Get-NetworkingMode)"
}

# Dot-sourcing (`. .\setup-wsl.ps1`) only defines the functions, for the tests and check.ps1.
if ($MyInvocation.InvocationName -ne '.') {
    Assert-Ready
    $system = New-WindowsSystem
    if ($WhatIfPreference) { $system = New-WhatIfSystem $system }
    if ($Revert) { Invoke-Revert $system } else { Invoke-Apply $system $WslConfig $Port $Profiles }
    if ($Restart) {
        if ($WhatIfPreference) { Write-Host 'What if: wsl --shutdown, stopping every running WSL distribution, and start it again' }
        else { Restart-Wsl }
    } elseif (-not $WhatIfPreference) {
        Say 'Done. Run wsl --shutdown (or this script with -Restart) for WSL to start with the new networking.'
    }
}
