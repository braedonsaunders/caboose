# Read-only checks of an existing Caboose installation. Run as the installing user.
$ErrorActionPreference = 'Stop'
function Require($condition, $message) { if (-not $condition) { throw $message }; Write-Host "ok: $message" }
$listed = (& wsl.exe --list --quiet | Out-String) -replace "`0", ''
Require ($LASTEXITCODE -eq 0 -and $listed -match '(?im)^\s*Caboose\s*$') 'Caboose distribution is registered'
$reportText = (& wsl.exe -d Caboose -u root --exec /usr/local/bin/caboose-wsl-ready | Out-String) -replace "`0", ''
Require ($LASTEXITCODE -eq 0) 'readiness command succeeded'
$line = ($reportText -split "`n" | Where-Object { $_.Trim().StartsWith('{') } | Select-Object -Last 1)
$ready = $line | ConvertFrom-Json
Require ($ready.healthy -eq $true) 'host is healthy'
$setup = Invoke-RestMethod -Uri 'http://127.0.0.1:7310/v1/setup' -TimeoutSec 10
if (-not $setup.claimed) {
  Require ($setup.codeRequired -eq $true -and $ready.setupCodePath) 'unclaimed host requires a setup code'
  & wsl.exe -d Caboose -u root --exec /usr/bin/test -s $ready.setupCodePath
  Require ($LASTEXITCODE -eq 0) 'setup code exists'
} else {
  Require (-not $ready.setupCodePath) 'claimed host has removed the setup code'
}
$task = Get-ScheduledTask -TaskName Caboose
Require ($null -ne $task -and $task.State -ne 'Disabled') 'startup task exists and is enabled'
Write-Host 'Check the notification-area icon, opening the console, phone reachability, and boot without sign-in separately.'
