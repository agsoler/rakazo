<#
.SYNOPSIS
Stops only the rakazo-personal Compose project.
.DESCRIPTION
Preserves its volumes, images, configuration, and recovery points. Throws when the project cannot
be addressed safely; it never targets the development or release projects.
.EXAMPLE
.\scripts\windows-personal\Stop-RakazoPersonal.ps1
#>
[CmdletBinding()]
param(
    [string]$DockerContext = "desktop-linux",
    [string]$DeploymentRoot,
    [string]$RecoveryRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "RakazoPersonal.Common.ps1")

$context = Get-RakazoPersonalCommandContext -DockerContext $DockerContext -DeploymentRoot $DeploymentRoot -RecoveryRoot $RecoveryRoot
[void](Assert-RakazoPersonalInitialized $context)
$composeArgs = Get-RakazoPersonalComposeArguments $context
Invoke-RakazoDocker -DockerContext $DockerContext -Arguments ($composeArgs + @("stop")) | Out-Null
Write-Host "Rakazo personal stable stopped. Its volumes and recovery points were preserved."
