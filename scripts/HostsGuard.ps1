#Requires -Version 5.1
<#
  HostsGuard.ps1 - cheap health check for the IPs AutoHosts pinned.

  Runs often (default every 5 minutes) and only probes what is already written:
    - an IP that stopped answering is dropped, the surviving ones stay
    - if every IP of a host is down the pins are kept anyway, because the system
      DNS answer is usually the one that made the site unreachable in the first
      place; the host is marked dead instead and a full re-selection is triggered
    - a full re-selection is rate limited, so a bad window does not turn into a
      probe storm

  Examples:
    powershell -NoProfile -ExecutionPolicy Bypass -File .\HostsGuard.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File .\HostsGuard.ps1 -DryRun
#>
param(
    [string]$Config,
    [int]$Budget = 0,
    [int]$CooldownMin = -1,
    [switch]$DryRun,
    [switch]$Quiet
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'common.ps1')

$paths = Get-AhPaths
$cfg   = Get-AhConfig -Path (Resolve-AhConfigPath -Path $Config)
$s     = $cfg.Settings
if ($Budget -le 0) { $Budget = [int]$s.guardBudgetMs }
if ($CooldownMin -lt 0) { $CooldownMin = [int]$s.reselectCooldownMin }
$retryMs    = [int]$s.guardRetryMs
$maxPerHost = [int]$s.maxIpPerHost
$allowed    = @($s.allowedStatus)

function Test-Pin {
    param([string]$Ip, [string]$HostName)
    $r = Invoke-AhProbe -Ip $Ip -HostName $HostName -Budget $Budget
    if ($null -ne $r -and ($allowed -contains $r.Status)) { return $true }
    Start-Sleep -Milliseconds $retryMs
    $r = Invoke-AhProbe -Ip $Ip -HostName $HostName -Budget $Budget
    return ($null -ne $r -and ($allowed -contains $r.Status))
}

$pins = Get-AhHostsPins -Path $paths.Hosts
if ($pins.Count -eq 0) {
    Write-AhLog -Path $paths.GuardLog -Quiet:$Quiet -Message 'no managed block in hosts, nothing to check'
    exit 0
}

$changed   = $false
$dead      = New-Object System.Collections.Generic.List[string]
$keptPins  = New-Object 'System.Collections.Specialized.OrderedDictionary'

foreach ($hostName in $pins.Keys) {
    $all  = @($pins[$hostName])
    $live = New-Object System.Collections.Generic.List[string]
    foreach ($ip in $all) {
        if ($live.Count -ge $maxPerHost) { break }
        if (Test-Pin -Ip $ip -HostName $hostName) { $live.Add($ip) }
    }
    if ($live.Count -eq 0) {
        $dead.Add($hostName)
        $keptPins[$hostName] = $all
    } else {
        if ($live.Count -ne $all.Count) { $changed = $true }
        $keptPins[$hostName] = $live
    }
}

if (-not $changed) {
    if ($dead.Count -eq 0) {
        Write-AhLog -Path $paths.GuardLog -Quiet:$Quiet -Message ('all ' + $pins.Count + ' hosts answering')
    } else {
        Write-AhLog -Path $paths.GuardLog -Quiet:$Quiet -Message ($dead.Count + ' of ' + $pins.Count + ' hosts unreachable (' + ($dead -join ', ') + '), pins kept until the path recovers')
    }
} elseif ($DryRun) {
    Write-AhLog -Path $paths.GuardLog -Quiet:$Quiet -Message ('dry run: would drop dead IPs, ' + $keptPins.Count + ' hosts kept')
} else {
    $written = Set-AhHostsPins -Path $paths.Hosts -Pins $keptPins -Note 'by HostsGuard.ps1 - delete this block to roll back' -BackupDir $paths.Backups -KeepBackups ([int]$s.backupKeep)
    ipconfig /flushdns | Out-Null
    Write-AhLog -Path $paths.GuardLog -Quiet:$Quiet -Message ('dead IPs dropped, ' + $written + ' records kept for ' + $keptPins.Count + ' hosts')
}

if ($dead.Count -gt 0) {
    $optimize = Join-Path $PSScriptRoot 'AutoHosts.ps1'
    $last = $null
    if (Test-Path -LiteralPath $paths.Stamp) {
        try { $last = [datetime](Get-Content -LiteralPath $paths.Stamp -Raw).Trim() } catch { $last = $null }
    }
    $due = ($null -eq $last) -or (((Get-Date) - $last).TotalMinutes -ge $CooldownMin)
    if (-not $due) {
        Write-AhLog -Path $paths.GuardLog -Quiet:$Quiet -Message ('re-selection cooling down (last ' + $last + ', ' + $CooldownMin + ' min)')
    } elseif ($DryRun) {
        Write-AhLog -Path $paths.GuardLog -Quiet:$Quiet -Message 'dry run: would start a full re-selection'
    } else {
        Write-AhLog -Path $paths.GuardLog -Quiet:$Quiet -Message 'starting full re-selection'
        (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | Set-Content -LiteralPath $paths.Stamp -Encoding UTF8
        try {
            $argList = @('-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $optimize + '"'), '-Quiet')
            Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -WindowStyle Hidden | Out-Null
        } catch {
            Write-AhLog -Path $paths.GuardLog -Quiet:$Quiet -Level WARN -Message ('could not start re-selection: ' + $_.Exception.Message)
        }
    }
}

exit 0
