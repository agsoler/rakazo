<#
.SYNOPSIS
Starts and health-checks only the configured rakazo-personal deployment.
.DESCRIPTION
Requires an active verified image manifest, starts the exact Compose project, and throws if image
identity or web/API health checks fail. It does not target ports 5200 or 5300.
.EXAMPLE
.\scripts\windows-personal\Start-RakazoPersonal.ps1
#>
[CmdletBinding()]
param(
    [string]$DockerContext = "desktop-linux",
    [string]$DeploymentRoot,
    [string]$RecoveryRoot,
    [ValidateRange(30, 600)][int]$TimeoutSeconds = 180
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "RakazoPersonal.Common.ps1")

$context = Get-RakazoPersonalCommandContext -DockerContext $DockerContext -DeploymentRoot $DeploymentRoot -RecoveryRoot $RecoveryRoot
[void](Assert-RakazoPersonalInitialized $context)
Assert-RakazoPersonalDeploymentIdentity $context
[void](Assert-RakazoPersonalActiveImageSet -Context $context -VerifyLocalImages)
$composeArgs = Get-RakazoPersonalComposeArguments $context
Invoke-RakazoDocker -DockerContext $DockerContext -Arguments ($composeArgs + @("config", "--quiet")) -Quiet | Out-Null
Invoke-RakazoDocker -DockerContext $DockerContext -Arguments ($composeArgs + @("up", "-d")) | Out-Null

if (-not (Wait-RakazoHttp -Uri "http://127.0.0.1:$($context.ApiPort)/health" -TimeoutSeconds $TimeoutSeconds)) {
    throw "Personal API did not become healthy on port $($context.ApiPort)."
}
if (-not (Wait-RakazoHttp -Uri "http://127.0.0.1:$($context.WebPort)/" -TimeoutSeconds $TimeoutSeconds)) {
    throw "Personal web UI did not become healthy on port $($context.WebPort)."
}
Write-Host "Rakazo personal stable is running: http://127.0.0.1:$($context.WebPort)"
