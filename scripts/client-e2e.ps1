<#
.SYNOPSIS
  Real-client L3 acceptance probe for X-SuperPlay Global Edge.

.DESCRIPTION
  Run this on a REAL Windows client after the WireGuard tunnel is connected.
  It verifies client-side evidence that repository CI cannot truthfully prove:
  - an active WireGuard adapter is visible;
  - the active WireGuard IPv4 MTU matches the repository stabilization policy;
  - the active WireGuard peer endpoint matches the selected direct/GAAP/relay ingress;
  - repeated DNS resolution succeeds;
  - a bounded full HTTPS payload can be transferred at a minimum useful rate;
  - GHCR is reachable over direct IPv4 HTTPS;
  - the public egress IPv4 equals the configured origin IPv4.

  Endpoint identity is intentionally separate from egress identity. In direct
  mode both may be the configured origin. In accelerated mode the endpoint may be
  a GAAP VIP or qualified GOST relay while the expected full-tunnel egress stays
  the configured origin.

  HTTP and egress probes intentionally use curl.exe with IPv4 forced and all
  configured proxies bypassed so the acceptance path measures WireGuard rather
  than a Windows system proxy / Clash / V2Ray path. On Schannel builds, revocation
  checks use best-effort mode so an offline CRL/OCSP endpoint is not confused
  with target-service unreachability.

  A HEAD/status response is not sufficient evidence. The GitHub probe performs a
  real GET, discards the body locally, and fails if curl cannot complete, the body
  is too small, or average transfer throughput is below the configured floor.
  This prevents the exact false-PASS observed when HEAD returned 200 while a real
  page stalled after tens of KiB.

  Test-NetConnection remains diagnostic only. A successful full HTTPS transfer is
  stronger end-to-end evidence than a standalone TCP helper probe.

  This script proves minimum P8 client usability, not long-term stability. P9
  still owns latency/jitter/loss/throughput evidence over time.

  Machine contract: the final stdout line is RESULT=PASS or RESULT=FAIL.
  Exit 0 = PASS, exit 1 = FAIL.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^(?:\d{1,3}\.){3}\d{1,3}$')]
    [string]$ServerPublicIp,

    [ValidatePattern('^(?:\d{1,3}\.){3}\d{1,3}$')]
    [string]$ExpectedEgressIp = '',

    [string]$ExpectedWireGuardEndpointHost = '',

    [ValidateRange(1, 65535)]
    [int]$ExpectedWireGuardEndpointPort = 51820,

    [ValidateRange(1200, 1420)]
    [int]$ExpectedWireGuardMtu = 1280,

    [ValidateRange(32768, 10485760)]
    [int]$PayloadMinBytes = 65536,

    [ValidateRange(1024, 104857600)]
    [int]$PayloadMinBytesPerSecond = 65536,

    [ValidateRange(10, 300)]
    [int]$PayloadMaxTimeSeconds = 90,

    [ValidateRange(1, 10)]
    [int]$DnsProbeCount = 3,

    [string]$ReportPath = ''
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($ExpectedEgressIp)) {
    $ExpectedEgressIp = $ServerPublicIp
}
if ([string]::IsNullOrWhiteSpace($ExpectedWireGuardEndpointHost)) {
    $ExpectedWireGuardEndpointHost = $ServerPublicIp
}
if ($ExpectedWireGuardEndpointHost -match '[\s"'']') {
    throw 'ExpectedWireGuardEndpointHost must be a plain IP address or hostname without spaces/quotes.'
}

$lines = New-Object System.Collections.Generic.List[string]
$failures = 0

function Add-Line {
    param([string]$Text)
    $script:lines.Add($Text)
    Write-Output $Text
}

function Pass {
    param([string]$Label, [string]$Detail = '')
    if ($Detail) { Add-Line "[PASS] $Label :: $Detail" }
    else { Add-Line "[PASS] $Label" }
}

function Fail {
    param([string]$Label, [string]$Detail = '')
    $script:failures += 1
    if ($Detail) { Add-Line "[FAIL] $Label :: $Detail" }
    else { Add-Line "[FAIL] $Label" }
}

function Info {
    param([string]$Label, [string]$Detail = '')
    if ($Detail) { Add-Line "[INFO] $Label :: $Detail" }
    else { Add-Line "[INFO] $Label" }
}

$curlCommand = Get-Command curl.exe -ErrorAction SilentlyContinue
$curlPath = if ($curlCommand) { $curlCommand.Source } else { $null }
$curlSupportsRevokeBestEffort = $false
if ($curlPath) {
    try {
        $curlHelp = (& $curlPath --help all 2>$null) -join "`n"
        $curlSupportsRevokeBestEffort = $curlHelp -match '--ssl-revoke-best-effort'
    }
    catch {
        $curlSupportsRevokeBestEffort = $false
    }
}

function Get-CurlCommonArgs {
    param(
        [int]$ConnectTimeoutSeconds = 10,
        [int]$MaxTimeSeconds = 20
    )

    $args = @(
        '--ipv4',
        '--noproxy', '*',
        '--connect-timeout', "$ConnectTimeoutSeconds",
        '--max-time', "$MaxTimeSeconds",
        '--silent',
        '--show-error'
    )
    if ($script:curlSupportsRevokeBestEffort) {
        $args += '--ssl-revoke-best-effort'
    }
    return $args
}

function Invoke-Curl {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    if (-not $script:curlPath) {
        return [pscustomobject]@{
            Ok = $false
            ExitCode = -1
            Output = 'curl.exe not found on this Windows client'
        }
    }

    try {
        $raw = & $script:curlPath @Arguments 2>&1
        $exitCode = $LASTEXITCODE
        $text = (($raw | ForEach-Object { "$_" }) -join "`n").Trim()
        return [pscustomobject]@{
            Ok = ($exitCode -eq 0)
            ExitCode = $exitCode
            Output = $text
        }
    }
    catch {
        return [pscustomobject]@{
            Ok = $false
            ExitCode = -1
            Output = $_.Exception.Message
        }
    }
}

function Test-HttpReachability {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $args = @(Get-CurlCommonArgs)
    $args += @('--head', '--output', 'NUL', '--write-out', '%{http_code}', $Uri)
    $probe = Invoke-Curl -Arguments $args

    if (-not $probe.Ok) {
        Fail $Label "curl_exit=$($probe.ExitCode) :: $($probe.Output)"
        return
    }

    $code = 0
    if (-not [int]::TryParse($probe.Output, [ref]$code)) {
        Fail $Label "unexpected curl output :: $($probe.Output)"
        return
    }

    if ($code -ge 100 -and $code -lt 500) {
        Pass $Label "HTTP $code"
    }
    else {
        Fail $Label "HTTP $code"
    }
}

function Test-HttpPayload {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $args = @(Get-CurlCommonArgs -ConnectTimeoutSeconds 15 -MaxTimeSeconds $PayloadMaxTimeSeconds)
    $metricFormat = 'EDGE_METRICS:%{http_code}|%{size_download}|%{speed_download}|%{time_total}'
    $args += @('--output', 'NUL', '--write-out', $metricFormat, $Uri)
    $probe = Invoke-Curl -Arguments $args

    $metricLine = @($probe.Output -split '\r?\n' | Where-Object { $_ -match 'EDGE_METRICS:' } | Select-Object -Last 1)
    $code = 0
    [double]$size = 0
    [double]$speed = 0
    [double]$time = 0
    $metricsParsed = $false

    if ($metricLine.Count -eq 1 -and $metricLine[0] -match 'EDGE_METRICS:(\d{3})\|([0-9.]+)\|([0-9.]+)\|([0-9.]+)') {
        $code = [int]$Matches[1]
        $size = [double]$Matches[2]
        $speed = [double]$Matches[3]
        $time = [double]$Matches[4]
        $metricsParsed = $true
    }

    $detail = if ($metricsParsed) {
        'HTTP={0} SIZE={1:N0} SPEED_BPS={2:N0} TIME_S={3:N2}' -f $code, $size, $speed, $time
    }
    else {
        "metrics_unavailable :: $($probe.Output)"
    }

    if (-not $probe.Ok) {
        Fail $Label "curl_exit=$($probe.ExitCode) :: $detail"
        return
    }
    if (-not $metricsParsed) {
        Fail $Label $detail
        return
    }
    if ($code -lt 200 -or $code -ge 400) {
        Fail $Label $detail
        return
    }
    if ($size -lt $PayloadMinBytes) {
        Fail $Label "$detail :: minimum_bytes=$PayloadMinBytes"
        return
    }
    if ($speed -lt $PayloadMinBytesPerSecond) {
        Fail $Label "$detail :: minimum_speed_bps=$PayloadMinBytesPerSecond"
        return
    }
    if ($time -gt $PayloadMaxTimeSeconds) {
        Fail $Label "$detail :: max_time_s=$PayloadMaxTimeSeconds"
        return
    }

    Pass $Label $detail
}

function Resolve-ExpectedEndpointAddresses {
    param([Parameter(Mandatory = $true)][string]$HostValue)

    $parsed = $null
    if ([System.Net.IPAddress]::TryParse($HostValue, [ref]$parsed)) {
        return @($parsed.IPAddressToString)
    }

    $resolved = @(Resolve-DnsName $HostValue -Type A -DnsOnly -ErrorAction Stop |
        Where-Object { $_.IPAddress } |
        Select-Object -ExpandProperty IPAddress -Unique)
    if ($resolved.Count -eq 0) {
        throw "No IPv4 address resolved for expected WireGuard endpoint host '$HostValue'."
    }
    return $resolved
}

Add-Line 'X-SuperPlay Global Edge - Windows L3 client E2E'
Add-Line "timestamp_utc=$([DateTime]::UtcNow.ToString('o'))"
Add-Line "server_public_ip=$ServerPublicIp"
Add-Line "expected_egress_ip=$ExpectedEgressIp"
Add-Line "expected_wireguard_endpoint_host=$ExpectedWireGuardEndpointHost"
Add-Line "expected_wireguard_endpoint_port=$ExpectedWireGuardEndpointPort"
Add-Line "expected_wireguard_mtu=$ExpectedWireGuardMtu"
Add-Line "payload_min_bytes=$PayloadMinBytes"
Add-Line "payload_min_speed_bps=$PayloadMinBytesPerSecond"
Add-Line "payload_max_time_s=$PayloadMaxTimeSeconds"
Add-Line "dns_probe_count=$DnsProbeCount"

# 1. Real WireGuard adapter and MTU evidence.
$wgAdapters = @()
try {
    $wgAdapters = @(Get-NetAdapter -ErrorAction Stop | Where-Object {
        $_.Status -eq 'Up' -and (
            $_.Name -match 'WireGuard' -or
            $_.InterfaceDescription -match 'WireGuard'
        )
    })
    if ($wgAdapters.Count -ge 1) {
        $names = ($wgAdapters | ForEach-Object { $_.Name }) -join ','
        Pass 'WireGuard adapter is Up' $names
    }
    else {
        Fail 'WireGuard adapter is Up' 'No active WireGuard adapter found. Connect the real tunnel first.'
    }
}
catch {
    Fail 'WireGuard adapter enumeration' $_.Exception.Message
}

if ($wgAdapters.Count -ge 1) {
    try {
        $mtuRows = @()
        foreach ($adapter in $wgAdapters) {
            $ipif = Get-NetIPInterface -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction Stop
            foreach ($row in @($ipif)) {
                $mtuRows += [pscustomobject]@{ Name = $adapter.Name; Mtu = [int]$row.NlMtu }
            }
        }
        $detail = ($mtuRows | ForEach-Object { "$($_.Name)=$($_.Mtu)" }) -join ','
        $matching = @($mtuRows | Where-Object { $_.Mtu -eq $ExpectedWireGuardMtu })
        if ($matching.Count -ge 1) {
            Pass 'WireGuard IPv4 MTU matches policy' $detail
        }
        else {
            Fail 'WireGuard IPv4 MTU matches policy' "expected=$ExpectedWireGuardMtu observed=$detail"
        }
    }
    catch {
        Fail 'WireGuard IPv4 MTU inspection' $_.Exception.Message
    }
}

# 2. Prove the active Windows tunnel is using the selected ingress endpoint.
# WireGuard for Windows exposes the standard wg(8) runtime interface. This gate
# prevents a stale direct profile from being mistaken for a successful
# relay acceptance merely because egress still equals the configured origin.
if ($wgAdapters.Count -ge 1) {
    $wgCommand = Get-Command wg.exe -ErrorAction SilentlyContinue
    $wgPath = if ($wgCommand) { $wgCommand.Source } else { $null }
    if (-not $wgPath -and $env:ProgramFiles) {
        $candidate = Join-Path $env:ProgramFiles 'WireGuard\wg.exe'
        if (Test-Path $candidate) { $wgPath = $candidate }
    }

    if (-not $wgPath) {
        Fail 'WireGuard endpoint identity' 'wg.exe not found. Official WireGuard for Windows wg(8) runtime access is required for endpoint proof.'
    }
    else {
        try {
            $expectedAddresses = @(Resolve-ExpectedEndpointAddresses -HostValue $ExpectedWireGuardEndpointHost)
            $observedEndpoints = New-Object System.Collections.Generic.List[string]
            $endpointMatched = $false

            foreach ($adapter in $wgAdapters) {
                $raw = & $wgPath show $adapter.Name endpoints 2>&1
                $wgExit = $LASTEXITCODE
                if ($wgExit -ne 0) {
                    Info 'WireGuard endpoint query' "adapter=$($adapter.Name) wg_exit=$wgExit"
                    continue
                }

                foreach ($line in @($raw)) {
                    $text = "$line".Trim()
                    if (-not $text) { continue }
                    if ($text -match '\s+(\[[^\]]+\]|[^\s:]+):(\d+)$') {
                        $observedHost = $Matches[1].Trim('[', ']')
                        $observedPort = [int]$Matches[2]
                        $observedEndpoints.Add("$observedHost`:$observedPort")
                        $hostMatch = ($expectedAddresses -contains $observedHost) -or
                            $observedHost.Equals($ExpectedWireGuardEndpointHost, [System.StringComparison]::OrdinalIgnoreCase)
                        if ($hostMatch -and $observedPort -eq $ExpectedWireGuardEndpointPort) {
                            $endpointMatched = $true
                        }
                    }
                }
            }

            $observedDetail = if ($observedEndpoints.Count -gt 0) {
                ($observedEndpoints.ToArray() | Select-Object -Unique) -join ','
            }
            else {
                'none'
            }
            $expectedDetail = "$ExpectedWireGuardEndpointHost`:$ExpectedWireGuardEndpointPort"
            if ($endpointMatched) {
                Pass 'WireGuard endpoint identity' "expected=$expectedDetail observed=$observedDetail"
            }
            else {
                Fail 'WireGuard endpoint identity' "expected=$expectedDetail resolved=$(($expectedAddresses -join ',')) observed=$observedDetail"
            }
        }
        catch {
            Fail 'WireGuard endpoint identity' $_.Exception.Message
        }
    }
}

# 3. Repeated DNS resolution. All attempts must succeed to avoid a cached or
# one-off success being treated as stable client DNS evidence.
$dnsSuccesses = 0
$dnsAddresses = New-Object System.Collections.Generic.List[string]
$dnsErrors = New-Object System.Collections.Generic.List[string]
for ($i = 1; $i -le $DnsProbeCount; $i++) {
    try {
        $dns = @(Resolve-DnsName github.com -Type A -DnsOnly -ErrorAction Stop | Where-Object { $_.IPAddress })
        if ($dns.Count -ge 1) {
            $dnsSuccesses += 1
            foreach ($address in ($dns | Select-Object -ExpandProperty IPAddress -Unique)) {
                if (-not $dnsAddresses.Contains($address)) { $dnsAddresses.Add($address) }
            }
        }
        else {
            $dnsErrors.Add("attempt=$i no_A_record")
        }
    }
    catch {
        $dnsErrors.Add("attempt=$i $($_.Exception.Message)")
    }
    if ($i -lt $DnsProbeCount) { Start-Sleep -Milliseconds 250 }
}
if ($dnsSuccesses -eq $DnsProbeCount) {
    Pass 'Repeated DNS resolution' "success=$dnsSuccesses/$DnsProbeCount addresses=$(($dnsAddresses.ToArray()) -join ',')"
}
else {
    Fail 'Repeated DNS resolution' "success=$dnsSuccesses/$DnsProbeCount errors=$(($dnsErrors.ToArray()) -join ' | ')"
}

# 4. Standalone TCP helper is diagnostic only. Full HTTPS payload below is authoritative.
try {
    $tcp = Test-NetConnection -ComputerName github.com -Port 443 -InformationLevel Detailed -WarningAction SilentlyContinue
    if ($tcp.TcpTestSucceeded) {
        Info 'TCP 443 diagnostic to github.com' ("reachable remote={0}" -f $tcp.RemoteAddress)
    }
    else {
        Info 'TCP 443 diagnostic to github.com' 'TcpTestSucceeded=false; full HTTPS payload remains authoritative'
    }
}
catch {
    Info 'TCP 443 diagnostic to github.com' ("unavailable: {0}; full HTTPS payload remains authoritative" -f $_.Exception.Message)
}

# 5. Real payload gate + registry reachability.
Test-HttpPayload -Uri 'https://github.com/' -Label 'GitHub HTTPS full payload'
Test-HttpReachability -Uri 'https://ghcr.io/v2/' -Label 'GHCR HTTPS direct'

# 6. Public egress IP must remain the configured origin for the full-tunnel model.
$egressArgs = @(Get-CurlCommonArgs)
$egressArgs += 'https://api.ipify.org'
$egressProbe = Invoke-Curl -Arguments $egressArgs
if (-not $egressProbe.Ok) {
    Fail 'Public egress IPv4 probe' "curl_exit=$($egressProbe.ExitCode) :: $($egressProbe.Output)"
}
else {
    $egress = $egressProbe.Output.Trim()
    Info 'Observed public egress IPv4' $egress
    if ($egress -eq $ExpectedEgressIp) {
        Pass 'Egress IP matches configured origin' $egress
    }
    else {
        Fail 'Egress IP matches configured origin' "expected=$ExpectedEgressIp observed=$egress"
    }
}

# 7. ICMP to the origin is informational only; providers/firewalls may block it.
try {
    $ping = Test-Connection -ComputerName $ServerPublicIp -Count 4 -ErrorAction Stop
    if ($ping) {
        $avg = [Math]::Round((($ping | Measure-Object -Property ResponseTime -Average).Average), 1)
        Info 'ICMP latency to configured origin' ("avg_ms={0}" -f $avg)
    }
}
catch {
    Info 'ICMP latency to configured origin' 'unavailable/blocked; not an L3 failure'
}

$result = if ($failures -eq 0) { 'PASS' } else { 'FAIL' }
Add-Line "failures=$failures"
Add-Line "RESULT=$result"

if (-not [string]::IsNullOrWhiteSpace($ReportPath)) {
    $parent = Split-Path -Parent $ReportPath
    if ($parent -and -not (Test-Path $parent)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    [System.IO.File]::WriteAllLines($ReportPath, $lines)
}

if ($failures -eq 0) { exit 0 }
exit 1
