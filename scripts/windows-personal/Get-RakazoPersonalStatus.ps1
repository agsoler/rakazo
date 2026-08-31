<#
.SYNOPSIS
Reports rakazo-personal containers, health, source commit, and exact images.
.DESCRIPTION
Performs read-only checks against only the configured rakazo-personal project. Throws when its
private configuration is missing; use -AsJson for machine-readable output.
.EXAMPLE
.\scripts\windows-personal\Get-RakazoPersonalStatus.ps1
#>
[CmdletBinding()]
param(
    [string]$DockerContext = "desktop-linux",
    [string]$DeploymentRoot,
    [string]$RecoveryRoot,
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "RakazoPersonal.Common.ps1")

$context = Get-RakazoPersonalCommandContext -DockerContext $DockerContext -DeploymentRoot $DeploymentRoot -RecoveryRoot $RecoveryRoot
$config = Assert-RakazoPersonalInitialized $context
$composeArgs = Get-RakazoPersonalComposeArguments $context
$psResult = Invoke-RakazoNativeCommand -FilePath "docker" -ArgumentList (@("--context", $DockerContext) + $composeArgs + @("ps", "--format", "json")) -Quiet -AllowFailure
$current = if (Test-Path -LiteralPath $context.CurrentImageSetFile) { Get-Content -Raw -LiteralPath $context.CurrentImageSetFile | ConvertFrom-Json } else { $null }
$webHealthy = $false
$apiHealthy = $false
try { $webHealthy = (Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$($context.WebPort)/" -TimeoutSec 3).StatusCode -eq 200 } catch {}
try { $apiHealthy = (Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$($context.ApiPort)/health" -TimeoutSec 3).StatusCode -eq 200 } catch {}
$replicationStatePath = Join-Path $context.DeploymentRoot "replication-state.json"
$replication = if (Test-Path -LiteralPath $replicationStatePath -PathType Leaf) { Get-Content -Raw -LiteralPath $replicationStatePath | ConvertFrom-Json } else { $null }
$status = [ordered]@{
    project = $context.Project
    web = [ordered]@{ url = "http://127.0.0.1:$($context.WebPort)"; healthy = $webHealthy }
    api = [ordered]@{ url = "http://127.0.0.1:$($context.ApiPort)/health"; healthy = $apiHealthy }
    sourceCommit = if ($current) { [string]$current.source.commit } else { "not deployed" }
    imageSetId = if ($current) { [string]$current.imageSetId } else { "not deployed" }
    nasConfigured = -not [string]::IsNullOrWhiteSpace([string]$config.nas.repository)
    replicationStatus = if ($replication) { [string]$replication.status } else { "not attempted" }
    pendingRecoveryPoints = if ($replication) { @($replication.recoveryPoints | Where-Object status -ne "synced").Count } else { 0 }
    composeExitCode = $psResult.ExitCode
    containers = @($psResult.Output)
}
if ($AsJson) { $status | ConvertTo-Json -Depth 8 }
else {
    Write-Host "Project: $($status.project)"
    Write-Host "Web: $($status.web.url) ($(if ($status.web.healthy) { 'healthy' } else { 'not reachable' }))"
    Write-Host "API: $($status.api.url) ($(if ($status.api.healthy) { 'healthy' } else { 'not reachable' }))"
    Write-Host "Commit: $($status.sourceCommit)"
    Write-Host "Image set: $($status.imageSetId)"
    Write-Host "Off-machine replication: $($status.replicationStatus) (pending points: $($status.pendingRecoveryPoints))"
    if ($psResult.Output.Count) { $psResult.Output | ForEach-Object { Write-Host $_ } }
}
