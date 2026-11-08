#Requires -Version 5.1
<#
  common.ps1 - shared helpers for AutoHosts.
  Dot-source this file; it is not meant to be run on its own.
#>

$script:AhMarkBegin = '# >>> AUTOHOSTS BEGIN (managed block, do not edit) >>>'
$script:AhMarkEnd   = '# <<< AUTOHOSTS END <<<'
$script:AhUserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'
$script:AhCrlf      = ([string][char]13) + ([string][char]10)

function Get-AhPaths {
    $root = if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'AutoHosts' } else { Join-Path $env:TEMP 'AutoHosts' }
    $backups = Join-Path $root 'backups'
    foreach ($d in @($root, $backups)) {
        if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }
    $sys = if ($env:SystemRoot) { $env:SystemRoot } else { 'C:/Windows' }
    [pscustomobject]@{
        Root       = $root
        OptimizeLog = Join-Path $root 'optimize.log'
        GuardLog   = Join-Path $root 'guard.log'
        Backups    = $backups
        Stamp      = Join-Path $root 'last-optimize.txt'
        Hosts      = Join-Path $sys 'System32/drivers/etc/hosts'
    }
}

function Write-AhLog {
    param([string]$Path, [string]$Message, [string]$Level = 'INFO', [switch]$Quiet)
    $line = ('{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message)
    if (-not $Quiet) { Write-Host $line }
    if ($Path) { try { Add-Content -LiteralPath $Path -Value $line -Encoding UTF8 } catch { } }
}

function Invoke-AhProbe {
    param([string]$Ip, [string]$HostName, [int]$Budget = 4000)
    $tcp = New-Object System.Net.Sockets.TcpClient
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $reader = $null
    try {
        $tcp.NoDelay = $true
        $tcp.ReceiveTimeout = $Budget
        $tcp.SendTimeout = $Budget
        $conn = $tcp.ConnectAsync($Ip, 443)
        if (-not $conn.Wait($Budget)) { return $null }
        if (-not $tcp.Connected) { return $null }

        # The probe measures reachability and timing only; certificate validation is
        # skipped here because no data is exchanged and the browser still validates.
        $acceptAll = [System.Net.Security.RemoteCertificateValidationCallback] { param($a, $b, $c, $d) $true }
        $ssl = New-Object System.Net.Security.SslStream($tcp.GetStream(), $false, $acceptAll)
        $ssl.ReadTimeout = $Budget
        $ssl.WriteTimeout = $Budget
        $protocols = [System.Security.Authentication.SslProtocols]::Tls12
        try { $protocols = $protocols -bor [System.Security.Authentication.SslProtocols]::Tls13 } catch { }
        try {
            $ssl.AuthenticateAsClient($HostName, $null, $protocols, $false)
        } catch {
            $ssl.AuthenticateAsClient($HostName, $null, [System.Security.Authentication.SslProtocols]::Tls12, $false)
        }
        $tlsMs = [int]$sw.ElapsedMilliseconds

        $req = 'GET / HTTP/1.1' + $script:AhCrlf +
               'Host: ' + $HostName + $script:AhCrlf +
               'User-Agent: ' + $script:AhUserAgent + $script:AhCrlf +
               'Accept: */*' + $script:AhCrlf +
               'Connection: close' + $script:AhCrlf + $script:AhCrlf
        $bytes = [System.Text.Encoding]::ASCII.GetBytes($req)
        $ssl.Write($bytes, 0, $bytes.Length)
        $ssl.Flush()

        $reader = New-Object System.IO.StreamReader($ssl, [System.Text.Encoding]::ASCII)
        $statusLine = $reader.ReadLine()
        $ttfbMs = [int]$sw.ElapsedMilliseconds
        if ([string]::IsNullOrWhiteSpace($statusLine)) { return $null }
        $parts = @($statusLine -split ' ')
        if ($parts.Count -lt 2) { return $null }
        $status = 0
        if (-not [int]::TryParse($parts[1], [ref]$status)) { return $null }
        return [pscustomobject]@{
            Ip = $Ip; Host = $HostName; Status = $status; TlsMs = $tlsMs; TtfbMs = $ttfbMs
        }
    } catch {
        return $null
    } finally {
        try { if ($null -ne $reader) { $reader.Dispose() } } catch { }
        try { $tcp.Close() } catch { }
    }
}

function Measure-AhEdge {
    param([string]$Ip, [string]$HostName, [int]$Rounds = 5, [int]$Budget = 4000, [int[]]$Allowed = @(200), [int]$MinOkPercent = 80)
    $tls = New-Object System.Collections.Generic.List[int]
    $lastStatus = 0
    for ($i = 0; $i -lt $Rounds; $i++) {
        $r = Invoke-AhProbe -Ip $Ip -HostName $HostName -Budget $Budget
        if ($null -eq $r) { continue }
        $lastStatus = $r.Status
        if ($Allowed -contains $r.Status) { $tls.Add($r.TlsMs) }
    }
    $need = [int][math]::Ceiling($Rounds * ($MinOkPercent / 100.0))
    if ($tls.Count -lt $need) { return $null }
    $sorted = @($tls | Sort-Object)
    $median = $sorted[[int][math]::Floor($sorted.Count / 2)]
    return [pscustomobject]@{
        Ip = $Ip; Host = $HostName
        Ok = $tls.Count; Fail = $Rounds - $tls.Count
        Best = $sorted[0]; Median = $median
        # Best reflects how good this path can be, median how it usually behaves;
        # a congested uplink swings both, so the score mixes them.
        Score = [int]((($sorted[0] * 0.5) + ($median * 0.5)))
        Status = $lastStatus
    }
}

function Get-AhHostsPins {
    param([string]$Path)
    $pins = New-Object 'System.Collections.Specialized.OrderedDictionary'
    if (-not (Test-Path -LiteralPath $Path)) { return $pins }
    $inBlock = $false
    foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
        $t = $line.Trim()
        if ($t -eq $script:AhMarkBegin) { $inBlock = $true; continue }
        if ($t -eq $script:AhMarkEnd) { $inBlock = $false; continue }
        if (-not $inBlock) { continue }
        if ($t -eq '' -or $t.StartsWith('#')) { continue }
        $parts = @($t -split '\s+')
        if ($parts.Count -lt 2) { continue }
        $hn = $parts[1].ToLowerInvariant()
        if (-not $pins.Contains($hn)) { $pins[$hn] = New-Object System.Collections.Generic.List[string] }
        $pins[$hn].Add($parts[0])
    }
    return $pins
}

function Set-AhHostsPins {
    param([string]$Path, $Pins, [string]$Note, [string]$BackupDir, [int]$KeepBackups = 20)
    $raw = @()
    if (Test-Path -LiteralPath $Path) { $raw = [System.IO.File]::ReadAllLines($Path) }

    if ($BackupDir -and (Test-Path -LiteralPath $Path)) {
        try {
            if (-not (Test-Path -LiteralPath $BackupDir)) { New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null }
            $bak = Join-Path $BackupDir ('hosts-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.bak')
            Copy-Item -LiteralPath $Path -Destination $bak -Force
            @(Get-ChildItem -LiteralPath $BackupDir -Filter 'hosts-*.bak' |
                Sort-Object LastWriteTime -Descending | Select-Object -Skip $KeepBackups) |
                ForEach-Object { try { Remove-Item -LiteralPath $_.FullName -Force } catch { } }
        } catch { }
    }

    $kept = New-Object System.Collections.Generic.List[string]
    $inBlock = $false
    foreach ($line in $raw) {
        $t = $line.Trim()
        if ($t -eq $script:AhMarkBegin) { $inBlock = $true; continue }
        if ($t -eq $script:AhMarkEnd) { $inBlock = $false; continue }
        if (-not $inBlock) { $kept.Add($line) }
    }
    while ($kept.Count -gt 0 -and $kept[$kept.Count - 1].Trim() -eq '') { $kept.RemoveAt($kept.Count - 1) }

    $lines = 0
    if ($null -ne $Pins -and $Pins.Count -gt 0) {
        $kept.Add('')
        $kept.Add($script:AhMarkBegin)
        $kept.Add('# auto-generated at ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' - ' + $Note)
        foreach ($hn in $Pins.Keys) {
            foreach ($ip in @($Pins[$hn])) { $kept.Add($ip + ' ' + $hn); $lines++ }
        }
        $kept.Add($script:AhMarkEnd)
    }

    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, (($kept -join $script:AhCrlf) + $script:AhCrlf), $enc)
    return $lines
}

function Resolve-AhConfigPath {
    param([string]$Path)
    if ($Path) {
        if (-not (Test-Path -LiteralPath $Path)) { throw ('config not found: ' + $Path) }
        return (Resolve-Path -LiteralPath $Path).Path
    }
    $candidate = Join-Path (Split-Path -Parent $PSScriptRoot) 'profiles.json'
    if (Test-Path -LiteralPath $candidate) { return $candidate }
    throw 'profiles.json not found next to the scripts; pass -Config <path>'
}

function Get-AhConfig {
    param([string]$Path)
    $json = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    $defaults = [ordered]@{
        rounds             = 5
        probeTimeoutMs     = 4000
        screenTimeoutMs    = 2500
        maxIpPerHost       = 3
        finalists          = 6
        minOkPercent       = 80
        guardBudgetMs      = 2500
        guardRetryMs       = 300
        reselectCooldownMin = 15
        backupKeep         = 20
        allowedStatus      = @(200, 201, 204, 301, 302, 303, 307, 308, 403, 404)
    }
    $settings = [ordered]@{}
    $given = $json.settings
    foreach ($key in $defaults.Keys) {
        $value = $null
        if ($null -ne $given -and $null -ne $given.PSObject.Properties[$key]) { $value = $given.$key }
        if ($null -eq $value) { $value = $defaults[$key] }
        $settings[$key] = $value
    }
    $groups = @()
    foreach ($g in @($json.groups)) {
        if ($null -eq $g -or [string]::IsNullOrWhiteSpace($g.probe) -or $null -eq $g.pool) { continue }
        $hosts = @()
        if ($null -ne $g.hosts) { $hosts = @($g.hosts | Where-Object { $_ }) }
        $groups += [pscustomobject]@{
            Name  = if ($g.name) { $g.name } else { $g.probe }
            Probe = $g.probe
            Pool  = @($g.pool)
            Hosts = $hosts
        }
    }
    if ($groups.Count -eq 0) { throw 'profiles.json has no usable group (each needs probe + pool)' }
    return [pscustomobject]@{ Settings = $settings; Groups = $groups }
}
