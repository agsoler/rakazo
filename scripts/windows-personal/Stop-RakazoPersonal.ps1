[CmdletBinding()]
param(
    [string]$DockerContext = "desktop-linux",
    [string]$DeploymentRoot,
    [string]$RecoveryRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "RakazoPersonal.Common.ps1")

$contextArgs = @{ DockerContext = $DockerContext }
if ($DeploymentRoot) { $contextArgs.DeploymentRoot = $DeploymentRoot }
if ($RecoveryRoot) { $contextArgs.RecoveryRoot = $RecoveryRoot }
$context = Get-RakazoPersonalContext @contextArgs
[void](Assert-RakazoPersonalInitialized $context)
$composeArgs = Get-RakazoPersonalComposeArguments $context
Invoke-RakazoDocker -DockerContext $DockerContext -Arguments ($composeArgs + @("stop")) | Out-Null
Write-Host "Rakazo personal stable stopped. Its volumes and recovery points were preserved."
