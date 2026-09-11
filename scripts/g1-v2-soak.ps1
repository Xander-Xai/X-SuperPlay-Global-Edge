<# Resumable application soak runner. Existing JSONL is resumed only when its session metadata and age sequence are valid. #>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][uri]$Target,
    [ValidateSet('HY2','REALITY','WIREGUARD')][string]$Transport = 'REALITY',
    [string]$ProxyUri = '', [int]$Iterations = 1, [int]$IntervalSeconds = 900,
    [string]$OutputPath = '', [string]$RttTarget = '', [ValidateRange(2,100)][int]$RttSamples = 5,
    [switch]$SkipProbe, [switch]$SkipRtt, [switch]$NewSession
)
$ErrorActionPreference = 'Stop'
if ($Iterations -lt 1) { throw 'Iterations must be >= 1' }
if ([string]::IsNullOrWhiteSpace($OutputPath)) { $OutputPath = Join-Path (Get-Location) '.temp\g1-v2-soak.jsonl' }
$parent = Split-Path -Parent $OutputPath
if ($parent -and -not (Test-Path $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
. (Join-Path $PSScriptRoot 'g1-v2-metrics.ps1')

function Read-ExistingSession([string]$path) {
    if (-not (Test-Path $path)) { return $null }
    $lines = @(Get-Content -Encoding UTF8 -Path $path); if ($lines.Count -eq 0) { return $null }
    $rows = @()
    foreach ($line in $lines) { try { $rows += ($line | ConvertFrom-Json -ErrorAction Stop) } catch { throw "SOAK_EVIDENCE=INVALID malformed JSONL: $($_.Exception.Message)" } }
    $ids = @($rows | ForEach-Object { $_.soak_session_id } | Select-Object -Unique)
    # ConvertFrom-Json materializes ISO timestamps as DateTime values and can
    # normalize away fractional precision/offsets. Preserve the JSON string
    # itself so a resumed session keeps byte-stable session metadata.
    $starts = @(
        $lines | ForEach-Object {
            if ($_ -match '"soak_started_at":"([^"]+)"') { $Matches[1] }
        } | Select-Object -Unique
    )
    if ($ids.Count -ne 1 -or [string]::IsNullOrWhiteSpace([string]$ids[0]) -or $starts.Count -ne 1 -or [string]::IsNullOrWhiteSpace([string]$starts[0])) { throw 'SOAK_EVIDENCE=INVALID inconsistent soak_session_id or soak_started_at' }
    $previous = -1
    foreach ($row in $rows) { if ($null -eq $row.connection_age_s -or [int]$row.connection_age_s -lt $previous) { throw 'SOAK_EVIDENCE=INVALID non-monotonic connection_age_s' }; $previous = [int]$row.connection_age_s }
    [ordered]@{ session_id=[string]$ids[0]; started_at=[string]$starts[0]; last_age=$previous }
}
$existing = if ($NewSession) { if (Test-Path $OutputPath) { throw '-NewSession requires a new OutputPath' }; $null } else { Read-ExistingSession $OutputPath }
if ($existing) {
    $sessionId=$existing.session_id
    $sessionStartedText=[string]$existing.started_at
    $sessionStarted=[DateTimeOffset]::Parse($sessionStartedText)
    $previousAge=$existing.last_age
} else {
    $sessionId=[guid]::NewGuid().ToString()
    $sessionStarted=[DateTimeOffset]::UtcNow
    $sessionStarted=$sessionStarted.AddTicks(-($sessionStarted.Ticks % [TimeSpan]::TicksPerMillisecond))
    $sessionStartedText=$sessionStarted.ToUniversalTime().ToString('o')
    $previousAge=-1
}

function Metric([string]$uri) {
    if ($SkipProbe) { return [ordered]@{ success=$false; http_status=$null; dns_latency_ms=$null; tcp_connect_latency_ms=$null; tls_latency_ms=$null; ttfb_ms=$null; total_latency_ms=$null; http_transfer_bps=$null; error='probe skipped for deterministic regression' } }
    $fmt='G1SOAK:%{http_code}|%{time_namelookup}|%{time_connect}|%{time_appconnect}|%{time_starttransfer}|%{time_total}|%{speed_download}'
    $args=@('--ipv4','--connect-timeout','10','--max-time','45','--silent','--show-error','--output','NUL','--write-out',$fmt)
    if ($ProxyUri) { $args += @('--proxy',$ProxyUri) } else { $args += @('--noproxy','*') }
    $raw=(& curl.exe @args $uri 2>&1 | Out-String).Trim()
    $m=[ordered]@{ success=$false; http_status=$null; dns_latency_ms=$null; tcp_connect_latency_ms=$null; tls_latency_ms=$null; ttfb_ms=$null; total_latency_ms=$null; http_transfer_bps=$null; error=$raw }
    if ($raw -match 'G1SOAK:(\d{3})\|([0-9.]+)\|([0-9.]+)\|([0-9.]+)\|([0-9.]+)\|([0-9.]+)\|([0-9.]+)') {
        $m.http_status=[int]$Matches[1]; $m.dns_latency_ms=[double]$Matches[2]*1000; $m.tcp_connect_latency_ms=[double]$Matches[3]*1000; $m.tls_latency_ms=[double]$Matches[4]*1000; $m.ttfb_ms=[double]$Matches[5]*1000; $m.total_latency_ms=[double]$Matches[6]*1000; $m.http_transfer_bps=[double]$Matches[7]; $m.success=($m.http_status -ge 200 -and $m.http_status -lt 400); $m.error=$null
    }
    return $m
}
function Rtt([string]$hostName, [int]$count) {
    if ($SkipRtt) { return Get-G1V2RttSummary @() 0 }
    $samples=@(); $failed=0
    for ($n=0; $n -lt $count; $n++) { try { $reply=@(Test-Connection -TargetName $hostName -Count 1 -TimeoutSeconds 2 -ErrorAction Stop) | Select-Object -Last 1; $latency=$reply.Latency; if ($null -eq $latency) { $latency=$reply.ResponseTime }; if ($null -ne $latency) { $samples += [double]$latency } else { $failed++ } } catch { $failed++ } }
    return Get-G1V2RttSummary $samples $count
}
$rttHost=if ($RttTarget) { $RttTarget } else { $Target.Host }
for ($i=1; $i -le $Iterations; $i++) {
    $metric=Metric $Target.AbsoluteUri; $rtt=Rtt $rttHost $RttSamples; $os=Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    $age=[int][math]::Floor(([DateTimeOffset]::UtcNow-$sessionStarted).TotalSeconds); if ($age -lt $previousAge) { throw 'SOAK_EVIDENCE=INVALID connection_age_s regressed during resume' }; $previousAge=$age
    $route=Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Sort-Object RouteMetric | Select-Object -First 1
    $row=[ordered]@{
        schema='g1-v2-soak.v2'; soak_session_id=$sessionId; soak_started_at=$sessionStartedText; timestamp_utc=[DateTime]::UtcNow.ToString('o'); sample=$i; connection_age_s=$age; transport=$Transport
        active_route=$(if ($route) { "$($route.NextHop) via $($route.InterfaceAlias)" } else { $null }); target=$Target.AbsoluteUri; success=$metric.success; http_status=$metric.http_status
        rtt_samples=$rtt.samples; rtt_p50_ms=$rtt.p50_ms; rtt_p95_ms=$rtt.p95_ms; jitter_ms=$rtt.jitter_ms; packet_loss_pct=$rtt.packet_loss_pct
        dns_latency_ms=$metric.dns_latency_ms; tcp_connect_latency_ms=$metric.tcp_connect_latency_ms; tls_latency_ms=$metric.tls_latency_ms; http_204_latency_ms=$null; ttfb_ms=$metric.ttfb_ms; total_latency_ms=$metric.total_latency_ms
        tcp_throughput_bps=$null; http_transfer_bps=$metric.http_transfer_bps; tcp_retransmits=$null; controlled_udp_loss_pct=$null; wg_latest_handshake_age_s=$null; wg_rx_bytes=$null; wg_tx_bytes=$null; cpu_pct=$null
        ram_available_bytes=$(if ($os) { [int64]$os.FreePhysicalMemory*1024 } else { $null }); softirq=$null; conntrack_count=$null; conntrack_max=$null; udp_receive_errors=$null; udp_send_errors=$null; nic_rx_drops=$null; nic_tx_drops=$null
        measurement_status=[ordered]@{ rtt=$rtt.measurement_status; http=$(if ($metric.success) { 'MEASURED' } else { 'UNAVAILABLE' }); server='UNAVAILABLE' }; measurement_source=[ordered]@{ rtt=$rtt.measurement_source; http='curl transfer timings'; server='g1-v2-server-state.sh required' }
        notes='Windows-only runner; server counters require g1-v2-server-state.sh'; error=$metric.error
    }
    ($row | ConvertTo-Json -Compress -Depth 6) | Add-Content -Encoding UTF8 -Path $OutputPath
    if ($i -lt $Iterations) { Start-Sleep -Seconds $IntervalSeconds }
}
Write-Output "OUTPUT=$OutputPath"; Write-Output "SOAK_RUNNER=ACTIVE samples=$Iterations interval_seconds=$IntervalSeconds session_id=$sessionId"
