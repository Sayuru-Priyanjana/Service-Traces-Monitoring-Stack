<#
.SYNOPSIS
  End-to-end check of the lab from Windows:
    1. all Prometheus targets are UP
    2. service_name label exists on process-exporter, systemd and OTel metrics
    3. Grafana serves the provisioned dashboards and the datasources are healthy
    4. every panel of every lab dashboard returns data, queried through Grafana's
       /api/ds/query (the same path the browser uses; works for Prometheus and Tempo)
  Run .\scripts\load-test.ps1 -Duration 2m first so the HTTP/trace panels have traffic.
.EXAMPLE
  .\scripts\verify.ps1
  .\scripts\verify.ps1 -Dashboards traces
#>
param(
    [string]$Prometheus = "http://192.168.56.10:9090",
    [string]$Grafana = "http://192.168.56.10:3000",
    [string]$GrafanaUser = "admin",
    [string]$GrafanaPassword = "admin",
    [string[]]$Dashboards = @("service-monitoring", "traces", "actions"),
    [string]$Range = "15m",
    [string]$Action = "POST /orders"   # value of $action used for the Actions dashboard
)
$ErrorActionPreference = "Stop"
$failures = 0
function Ok($msg)   { Write-Host "  [OK]   $msg" -ForegroundColor Green }
function Bad($msg)  { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:failures++ }
function Info($msg) { Write-Host "  [--]   $msg" -ForegroundColor DarkGray }
function PromQuery($expr) {
    (Invoke-RestMethod "$Prometheus/api/v1/query" -Body @{ query = $expr }).data.result
}
function LabelValues($expr, $label) {
    @(PromQuery "count by ($label) ($expr)" | ForEach-Object { $_.metric.$label } | Where-Object { $_ } | Sort-Object)
}
$auth = @{ Authorization = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${GrafanaUser}:${GrafanaPassword}")) }

Write-Host "`n1. Prometheus targets"
$targets = (Invoke-RestMethod "$Prometheus/api/v1/targets?state=active").data.activeTargets
foreach ($t in $targets | Sort-Object { $_.labels.job }, { $_.labels.instance }) {
    $name = "{0,-15} {1,-15} {2}" -f $t.labels.job, $t.labels.instance, $t.scrapeUrl
    if ($t.health -eq "up") { Ok $name } else { Bad "$name -> $($t.health) $($t.lastError)" }
}

Write-Host "`n2. service_name label"
$checks = [ordered]@{
    "process-exporter" = 'namedprocess_namegroup_num_procs'
    "systemd units"    = 'node_systemd_unit_state{service_name!=""}'
    "OTel HTTP server" = '{__name__=~"http_server_.*duration.*_count"}'
}
foreach ($k in $checks.Keys) {
    $names = LabelValues $checks[$k] "service_name"
    if ($names.Count) { Ok ("{0,-17} service_name = {1}" -f $k, ($names -join ", ")) } else { Bad "$k has no service_name series" }
}

Write-Host "`n3. Grafana dashboards and datasources"
$found = Invoke-RestMethod "$Grafana/api/search?type=dash-db" -Headers $auth
foreach ($d in $found | Sort-Object title) { Ok "dashboard: $($d.title)  ($Grafana$($d.url))" }
foreach ($ds in "prometheus", "tempo") {
    try {
        $h = Invoke-RestMethod "$Grafana/api/datasources/uid/$ds/health" -Headers $auth
        if ($h.status -eq "OK") { Ok "datasource $ds health: $($h.message)" } else { Bad "datasource ${ds}: $($h.message)" }
    } catch { if ($ds -eq "tempo") { Info "datasource tempo not provisioned" } else { Bad "datasource ${ds}: $_" } }
}

# Values for template variables, as Grafana would resolve "All".
$varValues = @{
    host    = @(LabelValues 'up{job="node"}' "instance")
    action  = @($Action)
}
$otelServices = LabelValues '{__name__=~"http_server_.*duration.*_count"}' "service_name"

function Expand([string]$text, [hashtable]$vars) {
    foreach ($k in $vars.Keys) {
        # one value: used as-is (like a single-select variable); several: a regex like "All"
        $re = @($vars[$k])[0]
        if ($vars[$k].Count -gt 1) { $re = "(" + (($vars[$k] | ForEach-Object { [regex]::Escape($_) }) -join "|") + ")" }
        $text = $text.Replace("`${${k}:regex}", $re).Replace("`$$k", $re)
    }
    $text.Replace('$__rate_interval', '1m').Replace('$__interval', '15s').Replace('$__range', $Range)
}

function PanelHasData($panel, [hashtable]$vars) {
    $queries = @()
    foreach ($t in $panel.targets) {
        $q = @{ refId = $t.refId; datasource = $t.datasource; intervalMs = 15000; maxDataPoints = 100 }
        if ($t.queryType -eq "serviceMap") {
            # The service map is assembled in the browser from these Prometheus series
            # (the Tempo backend rejects queryType=serviceMap), so check those instead.
            $q.datasource = @{ type = "prometheus"; uid = "prometheus" }
            $q.expr = "sum by (client, server) (rate(traces_service_graph_request_total[$Range]))"
            $q.instant = $true
        }
        elseif ($t.datasource.type -eq "prometheus") { $q.expr = Expand $t.expr $vars; $q.range = $true }
        else {
            $q.queryType = $t.queryType
            if ($t.query) { $q.query = Expand $t.query $vars }
            if ($t.limit) { $q.limit = $t.limit }
            if ($t.tableType) { $q.tableType = $t.tableType }
        }
        $queries += $q
    }
    $body = @{ queries = $queries; from = "now-$Range"; to = "now" } | ConvertTo-Json -Depth 10
    try { $res = Invoke-RestMethod -Method Post "$Grafana/api/ds/query" -Headers $auth -ContentType "application/json" -Body $body }
    catch { Write-Host "         query error: $($_.ErrorDetails.Message)" -ForegroundColor DarkYellow; return $false }
    foreach ($r in $res.results.PSObject.Properties.Value) {
        if ($r.error) { Write-Host "         query error: $($r.error)" -ForegroundColor DarkYellow }
        foreach ($f in $r.frames) {
            foreach ($col in $f.data.values) { if (@($col | Where-Object { $null -ne $_ }).Count -gt 0) { return $true } }
        }
    }
    return $false
}

Write-Host "`n4. Dashboard panels (via Grafana /api/ds/query, last $Range)"
foreach ($uid in $Dashboards) {
    try { $dash = (Invoke-RestMethod "$Grafana/api/dashboards/uid/$uid" -Headers $auth).dashboard }
    catch { Info "dashboard '$uid' not provisioned - skipped"; continue }
    Write-Host "  == $($dash.title)"
    # "All" for $service depends on the dashboard's own variable query.
    $svcVar = $dash.templating.list | Where-Object name -eq "service"
    $vars = $varValues.Clone()
    if ($svcVar) {
        $sq = Expand $svcVar.definition $varValues
        if ($sq -match '^label_values\((.*),\s*(\w+)\)$') { $vars.service = @(LabelValues $Matches[1] $Matches[2]) }
    }
    $inRepeat = $false
    foreach ($p in $dash.panels) {
        if ($p.type -eq "row") { $inRepeat = [bool]$p.repeat; Write-Host "  -- $($p.title)"; continue }
        $repeatVar = $null
        if ($inRepeat) { $repeatVar = ($dash.panels | Where-Object { $_.type -eq "row" -and $_.repeat } | Select-Object -First 1).repeat }
        # (a sentinel, not $null: PowerShell would unroll @($null) into zero iterations)
        $list = @("<all>")
        if ($repeatVar) { $list = $vars[$repeatVar] }
        foreach ($val in $list) {
            $v = $vars.Clone()
            if ($repeatVar) { $v[$repeatVar] = @($val) }
            $label = if ($repeatVar) { "{0,-38} [{1}]" -f $p.title, $val } else { $p.title }
            if (PanelHasData $p $v) { Ok $label }
            elseif ($uid -eq "service-monitoring" -and $p.title -match "Requests|Latency|Error" -and $val -notin $otelServices) {
                Info "$label  no data expected (not OTel-instrumented)"
            }
            else { Bad "$label  returned no data" }
        }
    }
}

Write-Host ""
if ($failures) { Write-Host "$failures check(s) failed" -ForegroundColor Red; exit 1 }
Write-Host "All checks passed" -ForegroundColor Green
