<#
.SYNOPSIS
  Stops / starts / restarts a systemd service on an app VM (watch "Services up" and
  the "Service running" panels).
.EXAMPLE
  .\scripts\service-control.ps1 -Service inventory -Action stop
  .\scripts\service-control.ps1 -Service inventory -Action start
  .\scripts\service-control.ps1 -Service nginx -Action restart
#>
param(
    [Parameter(Mandatory)][ValidateSet("orders", "inventory", "nginx", "redis")][string]$Service,
    [ValidateSet("stop", "start", "restart", "status")][string]$Action = "status"
)
$ErrorActionPreference = "Stop"
Set-Location (Split-Path $PSScriptRoot -Parent)

$vm = @{ orders = "app1"; nginx = "app1"; inventory = "app2"; redis = "app2" }[$Service]
$unit = @{ redis = "redis-server" }[$Service]
if (-not $unit) { $unit = $Service }

Write-Host "$Action $unit.service on $vm"
if ($Action -eq "status") {
    vagrant ssh $vm -c "systemctl status $unit.service --no-pager -n 5"
} else {
    vagrant ssh $vm -c "sudo systemctl $Action $unit.service && systemctl is-active $unit.service; true"
}
