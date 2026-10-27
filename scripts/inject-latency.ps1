<#
.SYNOPSIS
  Injects extra latency and/or errors into the inventory service through its
  /admin/chaos endpoint. Takes effect immediately; reset with -Reset.
  The setting lives in process memory, so restarting inventory.service also resets it.
.EXAMPLE
  .\scripts\inject-latency.ps1 -Ms 500                  # +500 ms on every inventory request
  .\scripts\inject-latency.ps1 -Ms 200 -ErrorRate 0.25  # +200 ms and 25% HTTP 500
  .\scripts\inject-latency.ps1 -Reset
  .\scripts\inject-latency.ps1 -Show
#>
param(
    [int]$Ms = 500,
    [double]$ErrorRate = 0.02,
    [switch]$Reset,
    [switch]$Show
)
$ErrorActionPreference = "Stop"
$url = "http://192.168.56.12:8002/admin/chaos"

if ($Show) { Invoke-RestMethod $url; return }
if ($Reset) { $Ms = 0; $ErrorRate = 0.02 }

$body = @{ latency_ms = $Ms; error_rate = $ErrorRate } | ConvertTo-Json
Invoke-RestMethod -Method Post -Uri $url -ContentType "application/json" -Body $body
