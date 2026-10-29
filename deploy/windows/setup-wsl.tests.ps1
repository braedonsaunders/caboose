# Unit tests for setup-wsl.ps1's pure logic: editing .wslconfig and reading netsh's
# portproxy table. They need no administrator, WSL or network, so they run anywhere
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

if ($failures -gt 0) { Write-Host "$failures failed"; exit 1 }
Write-Host 'all passed'
