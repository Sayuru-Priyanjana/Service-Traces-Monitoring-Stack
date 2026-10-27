<#
.SYNOPSIS
  Burns CPU on a VM with stress-ng (watch "Host CPU" and the per-service CPU panels).
.EXAMPLE
  .\scripts\stress-cpu.ps1 -Vm app1 -Seconds 120
  .\scripts\stress-cpu.ps1 -Vm app2 -Workers 1 -Load 80
#>
param(
    [ValidateSet("monitor", "app1", "app2")][string]$Vm = "app1",
    [int]$Seconds = 120,
    [int]$Workers = 0,     # 0 = one worker per CPU
    [int]$Load = 100       # percent per worker
)
$ErrorActionPreference = "Stop"
Set-Location (Split-Path $PSScriptRoot -Parent)

Write-Host "stress-ng on ${Vm}: $Seconds s, workers=$Workers, load=$Load%"
# A fixed method: the default ("all") includes instructions that crash with SIGILL when
# VirtualBox runs on top of Hyper-V.
vagrant ssh $Vm -c "stress-ng --cpu $Workers --cpu-method matrixprod --cpu-load $Load --timeout ${Seconds}s --metrics-brief"
