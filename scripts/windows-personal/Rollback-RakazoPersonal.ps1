[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RecoveryPointDirectory,
    [Parameter(Mandatory)][string]$ConfirmationPhrase,
    [string]$DockerContext = "desktop-linux",
    [string]$DeploymentRoot,
    [string]$RecoveryRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$arguments = @{
    RecoveryPointDirectory = $RecoveryPointDirectory
    ConfirmationPhrase = $ConfirmationPhrase
    DockerContext = $DockerContext
}
if ($DeploymentRoot) { $arguments.DeploymentRoot = $DeploymentRoot }
if ($RecoveryRoot) { $arguments.RecoveryRoot = $RecoveryRoot }
& (Join-Path $PSScriptRoot "Restore-RakazoPersonal.ps1") @arguments
