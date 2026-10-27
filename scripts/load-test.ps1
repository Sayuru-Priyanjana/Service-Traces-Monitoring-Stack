<#
.SYNOPSIS
  Runs a headless Locust load test from the monitor VM (Locust runs in Docker there,
  so nothing is installed on Windows).
.EXAMPLE
  .\scripts\load-test.ps1                       # 20 users, 5 minutes
  .\scripts\load-test.ps1 -Users 50 -Duration 10m
#>
param(
    [int]$Users = 20,
    [int]$SpawnRate = 5,
    [string]$Duration = "5m",
    [string]$TargetHost = "http://192.168.56.11"
)
$ErrorActionPreference = "Stop"
Set-Location (Split-Path $PSScriptRoot -Parent)

$image = "locustio/locust:2.46.6"
# Upload the current locustfile each run, so local edits take effect without re-provisioning.
vagrant upload scripts/locustfile.py /tmp/locust/locustfile.py monitor | Out-Null
$cmd = "docker run --rm --network host -v /tmp/locust:/mnt/locust:ro $image " +
       "-f /mnt/locust/locustfile.py --headless -u $Users -r $SpawnRate -t $Duration " +
       "-H $TargetHost --only-summary --exit-code-on-error 0"  # errors are intentional (flaky endpoint)

Write-Host "Running Locust: $Users users, spawn $SpawnRate/s, $Duration against $TargetHost"
vagrant ssh monitor -c $cmd
