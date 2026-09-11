function Get-G1V2Percentile {
    param([double[]]$Values, [ValidateRange(0,100)][double]$Percentile)
    $sorted = @($Values | Where-Object { $_ -ne $null } | Sort-Object)
    if ($sorted.Count -eq 0) { return $null }
    if ($sorted.Count -eq 1) { return [double]$sorted[0] }
    $rank = ($Percentile / 100.0) * ($sorted.Count - 1)
    $lower = [math]::Floor($rank); $upper = [math]::Ceiling($rank)
    if ($lower -eq $upper) { return [double]$sorted[$lower] }
    return [double]$sorted[$lower] + (($rank - $lower) * ([double]$sorted[$upper] - [double]$sorted[$lower]))
}
function Get-G1V2RttSummary {
    param([double[]]$Samples, [int]$Attempted)
    $values = @($Samples | Where-Object { $_ -ne $null }); $failed = [math]::Max(0, $Attempted - $values.Count)
    $loss = if ($Attempted -gt 0) { [math]::Round(100.0 * $failed / $Attempted, 2) } else { $null }
    [ordered]@{
        samples=$values; attempted=$Attempted; failed=$failed; packet_loss_pct=$loss
        p50_ms=if ($values.Count -gt 1) { [math]::Round((Get-G1V2Percentile $values 50), 3) } else { $null }
        p95_ms=if ($values.Count -gt 1) { [math]::Round((Get-G1V2Percentile $values 95), 3) } else { $null }
        jitter_ms=if ($values.Count -gt 1) { $d = for ($i=1; $i -lt $values.Count; $i++) { [math]::Abs($values[$i]-$values[$i-1]) }; [math]::Round(($d | Measure-Object -Average).Average, 3) } else { $null }
        measurement_status=if ($values.Count -gt 1) { 'MEASURED' } else { 'UNAVAILABLE' }; measurement_source='Windows Test-Connection samples'
    }
}
