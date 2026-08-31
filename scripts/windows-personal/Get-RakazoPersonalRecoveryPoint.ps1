<#
.SYNOPSIS
Retrieves one encrypted personal recovery point from configured Restic storage.
.DESCRIPTION
Restores into a new absolute directory and verifies the result. It does not alter rakazo-personal
containers or volumes and throws if the destination already exists or verification fails.
.EXAMPLE
.\scripts\windows-personal\Get-RakazoPersonalRecoveryPoint.ps1 -Latest -DestinationDirectory '<new-directory>'
#>
[CmdletBinding(DefaultParameterSetName = "Latest")]
param(
    [Parameter(ParameterSetName = "Snapshot", Mandatory)][string]$SnapshotId,
    [Parameter(ParameterSetName = "Latest")][switch]$Latest,
    [Parameter(Mandatory)][string]$DestinationDirectory,
    [string]$DockerContext = "desktop-linux",
    [string]$DeploymentRoot,
    [string]$RecoveryRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "RakazoPersonal.Common.ps1")

$context = Get-RakazoPersonalCommandContext -DockerContext $DockerContext -DeploymentRoot $DeploymentRoot -RecoveryRoot $RecoveryRoot
$config = Assert-RakazoPersonalInitialized $context
if (-not [IO.Path]::IsPathRooted($DestinationDirectory)) { throw "DestinationDirectory must be absolute." }
$destination = Get-RakazoFullPath $DestinationDirectory
if (Test-Path -LiteralPath $destination) { throw "Retrieval destination already exists: $destination" }
if (-not (Get-Command restic -CommandType Application -ErrorAction SilentlyContinue)) { throw "Restic is not installed." }
$repository = [string]$config.nas.repository
$passwordFile = [string]$config.nas.passwordFile
if (-not (Test-Path -LiteralPath $repository -PathType Container)) { throw "The NAS restic repository is unavailable." }
if (-not (Test-Path -LiteralPath $passwordFile -PathType Leaf)) { throw "Restic password file is unavailable." }

$oldRepository = $env:RESTIC_REPOSITORY
$oldPasswordFile = $env:RESTIC_PASSWORD_FILE
$env:RESTIC_REPOSITORY = $repository
$env:RESTIC_PASSWORD_FILE = $passwordFile
$snapshot = if ($PSCmdlet.ParameterSetName -eq "Latest") { "latest" } else { $SnapshotId }
try {
    Invoke-RakazoNativeCommand -FilePath "restic" -ArgumentList @("restore", $snapshot, "--tag", "rakazo-personal", "--target", $destination) | Out-Null
}
finally {
    $env:RESTIC_REPOSITORY = $oldRepository
    $env:RESTIC_PASSWORD_FILE = $oldPasswordFile
}
$recoveredRoot = Join-Path $destination (Split-Path -Leaf $context.RecoveryRoot)
if (-not (Test-Path -LiteralPath $recoveredRoot -PathType Container)) { throw "Restic restore completed without the expected personal recovery root." }
$recoveredPoints = @(Get-ChildItem -LiteralPath (Join-Path $recoveredRoot "recovery-points") -Directory -ErrorAction SilentlyContinue | Where-Object Name -notlike ".*.incomplete")
if (-not $recoveredPoints.Count) { throw "Retrieved material contains no complete personal recovery points." }
foreach ($point in $recoveredPoints) {
    & (Join-Path $PSScriptRoot "Test-RakazoPersonalRecoveryPoint.ps1") -RecoveryPointDirectory $point.FullName | Out-Null
}
Write-Host "Encrypted recovery material retrieved to: $recoveredRoot"
