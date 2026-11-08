#Requires -Version 5.1
<#
  AutoHosts.ps1 - pick the fastest edge IP for each configured host and pin it in
  the Windows hosts file. Direct connection only: no proxy, no VPN, no DNS change.

  For every group in profiles.json:
    1. screen every candidate IP of the pool with one quick TLS probe
    2. re-measure the fastest finalists several times and score them
    3. for each host in the group, keep the IPs that actually serve that host
  The result is written between two marker lines, so deleting that block rolls
  everything back. A backup of the previous hosts file is kept on every change.

  Examples:
    powershell -NoProfile -ExecutionPolicy Bypass -File .\AutoHosts.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File .\AutoHosts.ps1 -DryRun
    powershell -NoProfile -ExecutionPolicy Bypass -File .\AutoHosts.ps1 -Rounds 3
#>
param(
    [string]$Config,
    [int]$Rounds = 0,
    [switch]$DryRun,
    [switch]$Quiet
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'common.ps1')

$paths = Get-AhPaths
$cfg    = Get-AhConfig -Path (Resolve-AhConfigPath -Path $Config)
$s      = $cfg.Settings
if ($Rounds -le 0) { $Rounds = [int]$s.rounds }
$allowed   = @($s.allowedStatus)
$maxPerHost = [int]$s.maxIpPerHost

$mutex = New-Object System.Threading.Mutex($false, 'AutoHosts-Optimize')
if (-not $mutex.WaitOne(0)) {
    Write-AhLog -Path $paths.OptimizeLog -Message 'another optimize run is in progress, exiting' -Level WARN -Quiet:$Quiet
    exit 0
}

try {
    Write-AhLog -Path $paths.OptimizeLog -Quiet:$Quiet -Message ('start: screen ' + $s.screenTimeoutMs + 'ms, ' + $Rounds + ' rounds/' + $s.probeTimeoutMs + 'ms, ' + $maxPerHost + ' IP per host, ' + $cfg.Groups.Count + ' groups')

    $map = New-Object 'System.Collections.Specialized.OrderedDictionary'

    foreach ($group in $cfg.Groups) {
        Write-AhLog -Path $paths.OptimizeLog -Quiet:$Quiet -Message ('[' + $group.Name + '] screening ' + $group.Pool.Count + ' candidates against ' + $group.Probe)

        $screen = New-Object System.Collections.Generic.List[object]
        foreach ($ip in $group.Pool) {
            $r = Invoke-AhProbe -Ip $ip -HostName $group.Probe -Budget ([int]$s.screenTimeoutMs)
            if ($null -eq $r) { continue }
            if ($allowed -notcontains $r.Status) {
                # Reachable but serving something else (GitHub answers 400 from its API
                # hosts), pinning it would break the site instead of speeding it up.
                Write-AhLog -Path $paths.OptimizeLog -Quiet:$Quiet -Level WARN -Message ('  ' + $ip + ' status ' + $r.Status + ' is not this site, skipped')
                continue
            }
            $screen.Add($r)
        }
        if ($screen.Count -eq 0) {
            Write-AhLog -Path $paths.OptimizeLog -Quiet:$Quiet -Level ERROR -Message ('[' + $group.Name + '] no reachable candidate, leaving system DNS in place')
            continue
        }

        $finalists = @($screen | Sort-Object TlsMs | Select-Object -First ([int]$s.finalists))
        $confirmed = New-Object System.Collections.Generic.List[object]
        foreach ($f in $finalists) {
            $m = Measure-AhEdge -Ip $f.Ip -HostName $group.Probe -Rounds $Rounds -Budget ([int]$s.probeTimeoutMs) -Allowed $allowed -MinOkPercent ([int]$s.minOkPercent)
            if ($null -eq $m) {
                Write-AhLog -Path $paths.OptimizeLog -Quiet:$Quiet -Level WARN -Message ('  ' + $f.Ip + ' rejected: unstable')
                continue
            }
            Write-AhLog -Path $paths.OptimizeLog -Quiet:$Quiet -Message ('  ' + $f.Ip + ' ok=' + $m.Ok + '/' + $Rounds + ' best=' + $m.Best + 'ms median=' + $m.Median + 'ms score=' + $m.Score)
            $confirmed.Add($m)
        }
        if ($confirmed.Count -eq 0) {
            Write-AhLog -Path $paths.OptimizeLog -Quiet:$Quiet -Level ERROR -Message ('[' + $group.Name + '] no stable candidate, leaving system DNS in place')
            continue
        }

        $ranked = @($confirmed | Sort-Object Score, Best)
        Write-AhLog -Path $paths.OptimizeLog -Quiet:$Quiet -Message ('[' + $group.Name + '] ranked: ' + (($ranked | ForEach-Object { $_.Ip + '(score ' + $_.Score + ')' }) -join ', '))

        foreach ($hostName in (@($group.Probe) + @($group.Hosts))) {
            $picked = New-Object System.Collections.Generic.List[string]
            foreach ($c in $ranked) {
                if ($picked.Count -ge $maxPerHost) { break }
                if ($picked.Contains($c.Ip)) { continue }
                $probe = Invoke-AhProbe -Ip $c.Ip -HostName $hostName -Budget ([int]$s.probeTimeoutMs)
                if ($null -ne $probe -and ($allowed -contains $probe.Status)) { $picked.Add($c.Ip) }
            }
            if ($picked.Count -eq 0) {
                Write-AhLog -Path $paths.OptimizeLog -Quiet:$Quiet -Level WARN -Message ('  skip ' + $hostName + ': no candidate serves it, keeping system DNS')
            } else {
                $map[$hostName] = @($picked)
                Write-AhLog -Path $paths.OptimizeLog -Quiet:$Quiet -Message ('  pin ' + $hostName + ' -> ' + ($picked -join ', '))
            }
        }
    }

    if ($map.Count -eq 0) {
        Write-AhLog -Path $paths.OptimizeLog -Quiet:$Quiet -Level ERROR -Message 'nothing usable, hosts left untouched'
        exit 2
    }

    if ($DryRun) {
        Write-AhLog -Path $paths.OptimizeLog -Quiet:$Quiet -Message 'dry run: hosts not written'
        foreach ($k in $map.Keys) { foreach ($ip in @($map[$k])) { Write-Host ($ip + ' ' + $k) } }
        exit 0
    }

    $written = Set-AhHostsPins -Path $paths.Hosts -Pins $map -Note 'by AutoHosts.ps1 - delete this block to roll back' -BackupDir $paths.Backups -KeepBackups ([int]$s.backupKeep)
    ipconfig /flushdns | Out-Null
    (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | Set-Content -LiteralPath $paths.Stamp -Encoding UTF8
    Write-AhLog -Path $paths.OptimizeLog -Quiet:$Quiet -Message ('hosts updated: ' + $map.Count + ' hosts / ' + $written + ' records')

    Start-Sleep -Milliseconds 400
    $bad = 0
    foreach ($k in $map.Keys) {
        try {
            $addrs = @([System.Net.Dns]::GetHostAddresses($k) | ForEach-Object { $_.IPAddressToString })
            $miss = @($map[$k] | Where-Object { $addrs -notcontains $_ })
            if ($miss.Count -eq 0) {
                Write-AhLog -Path $paths.OptimizeLog -Quiet:$Quiet -Message ('  verify ok ' + $k)
            } else {
                $bad++
                Write-AhLog -Path $paths.OptimizeLog -Quiet:$Quiet -Level WARN -Message ('  verify mismatch ' + $k + ' got ' + ($addrs -join ',') + ' want ' + ($miss -join ','))
            }
        } catch {
            $bad++
            Write-AhLog -Path $paths.OptimizeLog -Quiet:$Quiet -Level WARN -Message ('  verify failed ' + $k + ': ' + $_.Exception.Message)
        }
    }
    if ($bad -gt 0) { Write-AhLog -Path $paths.OptimizeLog -Quiet:$Quiet -Level WARN -Message ($bad + ' hosts resolve differently than written') }
    Write-AhLog -Path $paths.OptimizeLog -Quiet:$Quiet -Message 'done'
    exit 0
} finally {
    try { $mutex.ReleaseMutex() } catch { }
    try { $mutex.Dispose() } catch { }
}
