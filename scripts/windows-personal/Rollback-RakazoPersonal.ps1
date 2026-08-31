<#
.SYNOPSIS
Rolls rakazo-personal back through the guarded restore command.
.DESCRIPTION
Delegates to the same verified, safety-backed destructive restore path and requires the exact
confirmation phrase. It never targets the development or release projects.
.EXAMPLE
.\scripts\windows-personal\Rollback-RakazoPersonal.ps1 -RecoveryPointDirectory '<recovery-point>' -ConfirmationPhrase 'RESTORE rakazo-personal'
#>
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
