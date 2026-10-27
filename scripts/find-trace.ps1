<#
.SYNOPSIS
  Runs a TraceQL search against Tempo and prints the newest matching trace as a span tree
  (service, span, duration, ERROR status, exception messages, user.action).
.EXAMPLE
  .\scripts\find-trace.ps1 '{ resource.service.name = "inventory" && duration > 500ms }'
  .\scripts\find-trace.ps1 '{ status = error && resource.service.name = "inventory" }'
  .\scripts\find-trace.ps1 '{ span.user.action = "POST /orders" }' -Minutes 5
#>
param(
    [Parameter(Mandatory, Position = 0)][string]$Query,
    [int]$Minutes = 15,
    [string]$Tempo = "http://192.168.56.10:3200"
)
$ErrorActionPreference = "Stop"

$now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$found = (Invoke-RestMethod "$Tempo/api/search" -Body @{ q = $Query; limit = 20; start = $now - 60 * $Minutes; end = $now }).traces
if (-not $found) { Write-Host "No trace matched $Query in the last $Minutes min" -ForegroundColor Yellow; exit 1 }
$hit = $found | Sort-Object { [decimal]$_.startTimeUnixNano } -Descending | Select-Object -First 1
Write-Host "$(@($found).Count) trace(s) matched. Newest: $($hit.traceID)  ($($hit.rootServiceName): $($hit.rootTraceName), $($hit.durationMs) ms)"
Write-Host "Grafana: http://192.168.56.10:3000/explore -> Tempo -> TraceQL -> paste the trace ID`n"

$spans = @()
foreach ($rs in (Invoke-RestMethod "$Tempo/api/v2/traces/$($hit.traceID)").trace.resourceSpans) {
    $svc = ($rs.resource.attributes | Where-Object key -eq "service.name").value.stringValue
    foreach ($s in $rs.scopeSpans.spans) {
        if ($s.name -match ' http (send|receive)$') { continue }   # ASGI internals: noise here
        $attr = @{}; foreach ($a in $s.attributes) { $attr[$a.key] = @($a.value.PSObject.Properties.Value)[0] }
        $exc = @($s.events | Where-Object name -eq "exception" | ForEach-Object {
            $t = ($_.attributes | Where-Object key -eq "exception.type").value.stringValue
            $m = ($_.attributes | Where-Object key -eq "exception.message").value.stringValue
            "$t`: $m" })
        $spans += [pscustomobject]@{
            id = $s.spanId; parent = $s.parentSpanId; service = $svc; name = $s.name; start = [decimal]$s.startTimeUnixNano
            ms = [math]::Round(([decimal]$s.endTimeUnixNano - [decimal]$s.startTimeUnixNano) / 1e6, 1)
            error = ($s.status.code -eq "STATUS_CODE_ERROR"); exc = $exc
            http = $attr["http.status_code"]; action = $attr["user.action"]
        }
    }
}
$ids = $spans.id
function Show($parent, $depth) {
    $kids = $spans | Where-Object { if ($parent) { $_.parent -eq $parent } else { -not $_.parent -or $_.parent -notin $ids } }
    foreach ($s in $kids | Sort-Object start) {
        $line = "{0}{1,-10} {2,-34} {3,8} ms" -f ("  " * $depth), $s.service, $s.name, $s.ms
        if ($s.http) { $line += "  http=$($s.http)" }
        if ($s.action) { $line += "  action=`"$($s.action)`"" }
        Write-Host $line -ForegroundColor $(if ($s.error) { "Red" } else { "Gray" }) -NoNewline
        Write-Host $(if ($s.error) { "  ERROR" } else { "" }) -ForegroundColor Red
        foreach ($e in $s.exc) { Write-Host ("{0}    exception: {1}" -f ("  " * $depth), $e) -ForegroundColor Yellow }
        Show $s.id ($depth + 1)
    }
}
Show $null 0
