$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'g1-v2-metrics.ps1')
$summary = Get-G1V2RttSummary ([double[]](10,11,12,13,50)) 5
if ($summary.p50_ms -ne 12 -or $summary.p95_ms -ne 42.6 -or $summary.packet_loss_pct -ne 0) { throw "Unexpected percentile summary: $($summary | ConvertTo-Json -Compress)" }
Write-Output 'TEST_REAL_RTT_PERCENTILES=PASS p50=12 p95=42.6'
$path = Join-Path $root '.temp\g1-v2-soak-regression.jsonl'
if (Test-Path $path) { Remove-Item -Force $path }
$soak = Join-Path $PSScriptRoot 'g1-v2-soak.ps1'
& powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $soak -Target 'http://127.0.0.1:1/' -Iterations 2 -IntervalSeconds 0 -OutputPath $path -SkipProbe -SkipRtt | Out-Null
$first = @(Get-Content -Encoding UTF8 $path | ForEach-Object { $_ | ConvertFrom-Json })
Start-Sleep -Seconds 1
& powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $soak -Target 'http://127.0.0.1:1/' -Iterations 1 -IntervalSeconds 0 -OutputPath $path -SkipProbe -SkipRtt | Out-Null
$rows = @(Get-Content -Encoding UTF8 $path | ForEach-Object { $_ | ConvertFrom-Json })
if ($rows.Count -ne 3) { throw "Expected 3 rows, got $($rows.Count)" }
if (($rows | ForEach-Object soak_session_id | Select-Object -Unique).Count -ne 1) { throw 'Session id changed on resume' }
if (($rows | ForEach-Object soak_started_at | Select-Object -Unique).Count -ne 1) { throw 'Session start changed on resume' }
$ages = @($rows | ForEach-Object { [int]$_.connection_age_s })
for ($i=1; $i -lt $ages.Count; $i++) { if ($ages[$i] -lt $ages[$i-1]) { throw 'connection_age_s regressed' } }
if ($ages[2] -lt $ages[1]) { throw 'resume age did not continue' }
Write-Output 'TEST_SOAK_RESUME_MONOTONIC_AGE=PASS'
