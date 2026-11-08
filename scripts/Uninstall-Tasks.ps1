#Requires -Version 5.1
<#
  Uninstall-Tasks.ps1 - remove the scheduled tasks and optionally the pinned block.

  Examples:
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Uninstall-Tasks.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Uninstall-Tasks.ps1 -RemovePins
#>
param(
    [string]$TaskPrefix = 'AutoHosts',
    [switch]$RemovePins
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'common.ps1')

foreach ($name in @(($TaskPrefix + '-Optimize'), ($TaskPrefix + '-Guard'))) {
    & schtasks.exe /Delete /TN $name /F 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { Write-Host ('removed task ' + $name) }
    else { Write-Host ('task not present: ' + $name) }
}

if ($RemovePins) {
    $paths = Get-AhPaths
    $written = Set-AhHostsPins -Path $paths.Hosts -Pins @{} -Note 'removed by Uninstall-Tasks.ps1' -BackupDir $paths.Backups
    ipconfig /flushdns | Out-Null
    Write-Host ('managed block removed from hosts, ' + $written + ' records left')
} else {
    Write-Host 'hosts block kept; run again with -RemovePins to drop it'
}
