<#
.SYNOPSIS
Checks, without changing anything, that a phone can reach a Caboose host in WSL directly.

.DESCRIPTION
Run on the Windows PC after setup-wsl.ps1 and a WSL restart, in an elevated PowerShell (the
firewall query needs it). It checks that .wslconfig asks for mirrored networking and the
running WSL uses it, that the Hyper-V firewall lets the port in, that no portproxy rule
still forwards it, and that caboose-host answers on the port. It prints the addresses a
phone uses. Exit code 0 when every check passes.

.EXAMPLE
.\check.ps1
.\check.ps1 -Port 7310 -Distro Ubuntu-24.04
#>
param(
    [ValidateRange(1, 65535)][int]$Port = 7310,
    [string]$Distro
)

$ErrorActionPreference = 'Stop'
$hostPort = $Port
# Dot-sourced with this script's parameters, which it would otherwise reset to its defaults.
. (Join-Path $PSScriptRoot 'setup-wsl.ps1') -Port $Port -Distro $Distro

$failed = 0
function Pass([string]$Text) { Write-Host "ok: $Text" }
function Fail([string]$Text) { $script:failed++; Write-Host "FAIL: $Text" }

$configured = Get-IniValue (Read-Lines $WslConfig) 'wsl2' 'networkingMode'
if ($configured -eq 'mirrored') { Pass "$WslConfig asks for mirrored networking" }
else { Fail "$WslConfig does not ask for mirrored networking (networkingMode=$(if ($configured) { $configured } else { 'unset, so NAT' })); run setup-wsl.ps1" }

$mode = Get-NetworkingMode
if ($mode -eq 'mirrored') { Pass 'WSL is running with mirrored networking' }
else { Fail "WSL is running with $mode networking (run wsl --shutdown after setup-wsl.ps1)" }

$rule = Get-NetFirewallHyperVRule -Name (Get-RuleName $hostPort) -ErrorAction SilentlyContinue
if ($rule -and "$($rule.Enabled)" -eq 'True' -and "$($rule.Action)" -eq 'Allow') { Pass "the Hyper-V firewall lets TCP $hostPort into WSL ($($rule.Profiles))" }
else { Fail "no enabled Hyper-V firewall rule allows TCP $hostPort into WSL" }

$proxies = @(& (New-WindowsSystem).GetProxies $hostPort)
if ($proxies.Count -eq 0) { Pass "no portproxy rule forwards $hostPort" }
else { Fail "a portproxy rule still forwards $hostPort ($(Format-Proxy $proxies[0]))" }

# Unauthenticated, the host answers 401: that it answers at all is the check.
try {
    $status = (Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 "http://127.0.0.1:$hostPort/v1/health").StatusCode
} catch [System.Net.WebException] {
    $status = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
} catch { $status = 0 }
if ($status -in 200, 401) { Pass "caboose-host answers on port $hostPort" }
else { Fail "nothing answers on http://127.0.0.1:$hostPort (is caboose-host running in WSL?)" }

$addresses = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' -and $_.InterfaceAlias -notlike 'vEthernet*' } |
    ForEach-Object { "http://$($_.IPAddress):$hostPort  ($($_.InterfaceAlias))" }
if ($addresses) { Write-Host "A phone reaches Caboose at:`n  $($addresses -join "`n  ")" }

if ($failed -gt 0) { Write-Host "$failed check(s) failed"; exit 1 }
Write-Host 'all checks passed'
