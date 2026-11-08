#Requires -Version 5.1
<#
  Install-Tasks.ps1 - register the two scheduled tasks that keep hosts pinned.

  No administrator rights needed: the tasks run as the current user with a
  limited token, which is enough because the hosts file is writable for the
  interactive user on a normal desktop install.

  Examples:
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-Tasks.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-Tasks.ps1 -OptimizeMinutes 60 -GuardMinutes 10
#>
param(
    [int]$OptimizeMinutes = 30,
    [int]$GuardMinutes = 5,
    [string]$TaskPrefix = 'AutoHosts',
    [switch]$RunNow
)

$ErrorActionPreference = 'Stop'
$optimize = Join-Path $PSScriptRoot 'AutoHosts.ps1'
$guard    = Join-Path $PSScriptRoot 'HostsGuard.ps1'
foreach ($f in @($optimize, $guard)) {
    if (-not (Test-Path -LiteralPath $f)) { throw ('missing script: ' + $f) }
}

function Register-Task {
    param([string]$Name, [string]$ScriptPath, [int]$EveryMinutes)
    $action = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $ScriptPath + '"'
    & schtasks.exe /Create /TN $Name /TR $action /SC MINUTE /MO $EveryMinutes /RL LIMITED /F 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw ('schtasks failed for ' + $Name + ' (exit ' + $LASTEXITCODE + ')') }
    Write-Host ('registered ' + $Name + ' every ' + $EveryMinutes + ' min')
}

Register-Task -Name ($TaskPrefix + '-Optimize') -ScriptPath $optimize -EveryMinutes $OptimizeMinutes
Register-Task -Name ($TaskPrefix + '-Guard') -ScriptPath $guard -EveryMinutes $GuardMinutes

if ($RunNow) {
    & schtasks.exe /Run /TN ($TaskPrefix + '-Optimize') 2>&1 | Out-Null
    Write-Host 'optimize task started now'
}

Write-Host ''
Write-Host 'logs: %LOCALAPPDATA%\AutoHosts\optimize.log / guard.log'
Write-Host ('remove everything later with: powershell -File ' + (Join-Path $PSScriptRoot 'Uninstall-Tasks.ps1') + ' -RemovePins')
