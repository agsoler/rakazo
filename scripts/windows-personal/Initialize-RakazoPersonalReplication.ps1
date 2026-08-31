<#
.SYNOPSIS
Configures optional encrypted Restic replication for personal recovery points.
.DESCRIPTION
Writes only ignored private configuration. Repository creation occurs only with
-InitializeRepository; password generation occurs only with -GeneratePasswordFile. Throws on error.
.EXAMPLE
.\scripts\windows-personal\Initialize-RakazoPersonalReplication.ps1 -Repository '<absolute-path>' -PasswordFile '<password-file>'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Repository,
    [string]$PasswordFile,
    [switch]$GeneratePasswordFile,
    [switch]$InitializeRepository,
    [string]$DockerContext = "desktop-linux",
    [string]$DeploymentRoot,
    [string]$RecoveryRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "RakazoPersonal.Common.ps1")

$context = Get-RakazoPersonalCommandContext -DockerContext $DockerContext -DeploymentRoot $DeploymentRoot -RecoveryRoot $RecoveryRoot
$config = Assert-RakazoPersonalInitialized $context
if (-not [IO.Path]::IsPathRooted($Repository)) { throw "Repository must be an absolute local or network path." }
$repositoryPath = Get-RakazoFullPath $Repository
$passwordPath = if ($PasswordFile) { Get-RakazoFullPath $PasswordFile } else { Join-Path $context.DeploymentRoot "restic-password.txt" }

if ($GeneratePasswordFile) {
    if (Test-Path -LiteralPath $passwordPath) { throw "Password file already exists; refusing to overwrite it." }
    New-RakazoHexSecret 32 | Set-Content -NoNewline -LiteralPath $passwordPath -Encoding ascii
    Protect-RakazoPrivatePath $passwordPath
}
if (-not (Test-Path -LiteralPath $passwordPath -PathType Leaf)) { throw "Restic password file does not exist. Supply it or use -GeneratePasswordFile." }

$config.nas.repository = $repositoryPath
$config.nas.passwordFile = $passwordPath
Write-RakazoJsonFile -Value $config -Path $context.ConfigFile
Protect-RakazoPrivatePath $context.ConfigFile
Write-Host "Encrypted replication configuration saved in ignored local configuration."
Write-Host "Store an independent copy of the restic password before relying on disaster recovery."

if ($InitializeRepository) {
    & (Join-Path $PSScriptRoot "Sync-RakazoPersonalBackups.ps1") -DockerContext $DockerContext -DeploymentRoot $context.DeploymentRoot -RecoveryRoot $context.RecoveryRoot -InitializeRepository
}
