<#
.SYNOPSIS
  Read-only Windows route/TUN/DNS/MTU evidence collector for G1 v2.
.DESCRIPTION
  Captures state only. It does not enable/disable WireGuard, Mihomo, Clash,
  routes, firewall rules, adapters or DNS settings.
#>
[CmdletBinding()]
param([string]$OutputPath = '')

$ErrorActionPreference = 'Continue'
$result = [ordered]@{
    schema = 'g1-v2-windows-state.v1'
    timestamp_utc = [DateTime]::UtcNow.ToString('o')
    computer = $env:COMPUTERNAME
    route_print = (& route.exe print 2>&1 | Out-String).Trim()
    ip_configuration = @(Get-NetIPConfiguration | Select-Object InterfaceAlias,InterfaceIndex,IPv4Address,IPv4DefaultGateway,DNSServer)
    adapters = @(Get-NetAdapter | Select-Object Name,InterfaceDescription,Status,ifIndex,MacAddress,LinkSpeed)
    ip_interfaces = @(Get-NetIPInterface | Select-Object InterfaceAlias,InterfaceIndex,AddressFamily,ConnectionState,NlMtu,AutomaticMetric,InterfaceMetric)
    dns_servers = @(Get-DnsClientServerAddress | Select-Object InterfaceAlias,InterfaceIndex,AddressFamily,ServerAddresses)
    suspected_tun = @(Get-NetAdapter | Where-Object {
        $_.Name -match '(?i)wireguard|mihomo|clash|tun|wintun|sing-box|v2ray' -or
        $_.InterfaceDescription -match '(?i)wireguard|wintun|mihomo|clash|tun|sing-box|v2ray'
    } | Select-Object Name,InterfaceDescription,Status,ifIndex)
    default_routes = @(Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
        Select-Object DestinationPrefix,NextHop,InterfaceAlias,InterfaceIndex,RouteMetric,Publish,State)
}
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path (Get-Location) ('.temp\g1-v2-windows-state-{0}.json' -f (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ'))
}
$parent = Split-Path -Parent $OutputPath
if ($parent -and -not (Test-Path $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
$result | ConvertTo-Json -Depth 20 | Set-Content -Encoding UTF8 -Path $OutputPath
Write-Output "OUTPUT=$OutputPath"
Write-Output 'WINDOWS_BASELINE=COLLECTED'
Write-Output ('SUSPECTED_TUN_COUNT={0}' -f @($result.suspected_tun).Count)
