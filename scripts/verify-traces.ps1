<#
.SYNOPSIS
  Phase 2 (tracing) evidence, run from Windows after some load:
    1. Tempo /ready (from inside the monitor VM)
    2. a trace that contains spans from orders AND inventory (and redis), printed as a tree
    3. Tempo metrics-generator series in Prometheus (service graph + span metrics)
    4. exemplars: OTel SDK exemplars (via collector) and span-metrics exemplars (via remote write)
.EXAMPLE
  .\scripts\load-test.ps1 -Duration 2m
  .\scripts\verify-traces.ps1
#>
param(
    [string]$Tempo = "http://192.168.56.10:3200",
    [string]$Prometheus = "http://192.168.56.10:9090"
)
$ErrorActionPreference = "Stop"
Set-Location (Split-Path $PSScriptRoot -Parent)
$failures = 0
function Ok($msg)  { Write-Host "  [OK]   $msg" -ForegroundColor Green }
function Bad($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:failures++ }

Write-Host "`n1. Tempo ready (curl inside the monitor VM)"
$ready = (vagrant ssh monitor -c "curl -s localhost:3200/ready" 2>$null | Out-String).Trim()
if ($ready -eq "ready") { Ok "GET localhost:3200/ready -> $ready" } else { Bad "Tempo /ready -> '$ready'" }

Write-Host "`n2. A connected trace: orders -> inventory -> redis"
# TraceQL structural query: an inventory span that is a descendant of an orders span.
$q = '{ resource.service.name = "orders" } >> { resource.service.name = "inventory" }'
$now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$search = Invoke-RestMethod "$Tempo/api/search" -Body @{ q = $q; limit = 5; start = $now - 3600; end = $now }
if (-not $search.traces) { Bad "no trace matched: $q" }
else {
    $tid = $search.traces[0].traceID
    Ok "TraceQL $q -> $(@($search.traces).Count) trace(s); using $tid ($($search.traces[0].rootTraceName))"
    $trace = Invoke-RestMethod "$Tempo/api/v2/traces/$tid"
    $spans = @()
    foreach ($rs in $trace.trace.resourceSpans) {
        $svc = ($rs.resource.attributes | Where-Object key -eq "service.name").value.stringValue
        foreach ($ss in $rs.scopeSpans) {
            foreach ($s in $ss.spans) {
                $db = ($s.attributes | Where-Object key -eq "db.system").value.stringValue
                $ms = [math]::Round(([decimal]$s.endTimeUnixNano - [decimal]$s.startTimeUnixNano) / 1e6, 1)
                $spans += [pscustomobject]@{ id = $s.spanId; parent = $s.parentSpanId; service = $svc; name = $s.name
                                             kind = $s.kind; db = $db; ms = $ms; start = [decimal]$s.startTimeUnixNano }
            }
        }
    }
    function PrintTree($parent, $depth) {
        foreach ($s in $spans | Where-Object { "$($_.parent)" -eq "$parent" } | Sort-Object start) {
            $tag = if ($s.db) { " [db.system=$($s.db)]" } else { "" }
            Write-Host ("         {0}{1,-10} {2}{3}  {4} ms" -f ("  " * $depth), $s.service, $s.name, $tag, $s.ms)
            PrintTree $s.id ($depth + 1)
        }
    }
    $root = $spans | Where-Object { -not $_.parent }
    PrintTree "" 0
    $services = $spans.service | Sort-Object -Unique
    if ($services -contains "orders" -and $services -contains "inventory") { Ok "trace $tid has spans from: $($services -join ', ')" } else { Bad "services in trace: $($services -join ', ')" }
    if ($spans | Where-Object db -eq "redis") { Ok "redis client spans present ($(@($spans | Where-Object db -eq 'redis').Count))" } else { Bad "no redis spans in trace $tid" }
    if (@($root).Count -eq 1) { Ok "one root span -> a single connected trace (traceparent propagated)" } else { Bad "$(@($root).Count) root spans" }
}

Write-Host "`n3. Tempo metrics-generator series in Prometheus"
foreach ($m in "traces_service_graph_request_total", "traces_spanmetrics_calls_total", "traces_spanmetrics_latency_bucket") {
    $r = (Invoke-RestMethod "$Prometheus/api/v1/query" -Body @{ query = "count($m)" }).data.result
    if ($r) { Ok "$m : $($r[0].value[1]) series" } else { Bad "$m missing" }
}
$edges = (Invoke-RestMethod "$Prometheus/api/v1/query" -Body @{ query = 'sum by (client, server) (traces_service_graph_request_total)' }).data.result
foreach ($e in $edges) { Ok ("service graph edge {0} -> {1}" -f $e.metric.client, $e.metric.server) }

Write-Host "`n4. Exemplars (last 15 min)"
$end = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
foreach ($m in "http_server_duration_milliseconds_bucket", "traces_spanmetrics_latency_bucket") {
    $ex = (Invoke-RestMethod "$Prometheus/api/v1/query_exemplars" -Body @{ query = $m; start = $end - 900; end = $end }).data
    $n = ($ex | ForEach-Object { @($_.exemplars).Count } | Measure-Object -Sum).Sum
    if ($n) {
        $first = $ex[0].exemplars[0].labels
        Ok ("{0}: {1} exemplars, labels: {2}" -f $m, $n, (($first.PSObject.Properties | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join " "))
    } else { Write-Host "  [--]   ${m}: no exemplars" -ForegroundColor DarkYellow }
}

Write-Host ""
if ($failures) { Write-Host "$failures check(s) failed" -ForegroundColor Red; exit 1 }
Write-Host "All trace checks passed" -ForegroundColor Green
