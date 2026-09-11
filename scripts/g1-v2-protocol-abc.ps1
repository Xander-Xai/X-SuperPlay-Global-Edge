<#
.SYNOPSIS
  One application-level machine-readable sample for the WG/HY2/Reality ABC test.
.DESCRIPTION
  Run this on the same Windows host, against the same target and adjacent time
  windows. Select the active transport outside this script (WG profile,
  Mihomo node, or explicit HTTP proxy). This script never changes routes.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('WIREGUARD','HY2','REALITY')][string]$Transport,
    [Parameter(Mandatory = $true)][uri]$Target,
    [string]$ProxyUri = '',
    [int]$Samples = 5,
    [int]$IntervalSeconds = 5,
    [string]$OutputPath = ''
)
$ErrorActionPreference = 'Stop'
if ($Samples -lt 1 -or $Samples -gt 1000) { throw 'Samples must be 1..1000' }
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path (Get-Location) ('.temp\g1-v2-abc-{0}-{1}.jsonl' -f $Transport.ToLowerInvariant(), (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ'))
}
$parent = Split-Path -Parent $OutputPath
if ($parent -and -not (Test-Path $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
$start = Get-Date
for ($i = 1; $i -le $Samples; $i++) {
    $fmt = 'G1V2:%{http_code}|%{time_namelookup}|%{time_connect}|%{time_appconnect}|%{time_starttransfer}|%{time_total}'
    $args = @('--ipv4','--connect-timeout','10','--max-time','30','--silent','--show-error','--output','NUL','--write-out',$fmt)
    if (-not [string]::IsNullOrWhiteSpace($ProxyUri)) { $args += @('--proxy',$ProxyUri) } else { $args += @('--noproxy','*') }
    $raw = (& curl.exe @args $Target.AbsoluteUri 2>&1 | Out-String).Trim()
    $ok = $false; $status = $null; $dns = $null; $connect = $null; $tls = $null; $ttfb = $null; $total = $null
    if ($raw -match 'G1V2:(\d{3})\|([0-9.]+)\|([0-9.]+)\|([0-9.]+)\|([0-9.]+)\|([0-9.]+)') {
        $status = [int]$Matches[1]; $dns = [double]$Matches[2] * 1000; $connect = [double]$Matches[3] * 1000
        $tls = [double]$Matches[4] * 1000; $ttfb = [double]$Matches[5] * 1000; $total = [double]$Matches[6] * 1000
        $ok = ($status -ge 200 -and $status -lt 400)
    }
    $row = [ordered]@{
        schema='g1-v2-protocol-abc.v1'; timestamp_utc=[DateTime]::UtcNow.ToString('o'); sample=$i
        connection_age_s=[int]((Get-Date) - $start).TotalSeconds; transport=$Transport; target=$Target.AbsoluteUri
        proxy=$ProxyUri; success=$ok; http_status=$status; dns_latency_ms=$dns; tcp_connect_latency_ms=$connect
        tls_latency_ms=$tls; ttfb_ms=$ttfb; total_latency_ms=$total; raw_error=$(if ($ok) { $null } else { $raw })
    }
    ($row | ConvertTo-Json -Compress) | Add-Content -Encoding UTF8 -Path $OutputPath
    if ($i -lt $Samples) { Start-Sleep -Seconds $IntervalSeconds }
}
Write-Output "OUTPUT=$OutputPath"
Write-Output "PROTOCOL_ABC_TRANSPORT=$Transport"
