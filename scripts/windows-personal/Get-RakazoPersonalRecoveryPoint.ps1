<#
.SYNOPSIS
Retrieves one encrypted personal recovery point from configured Restic storage.
.DESCRIPTION
Restores into a new absolute directory, verifies the result, and imports its immutable image sets
and recovery points into the configured local recovery catalogue used by the Restore launcher. It
does not alter rakazo-personal containers or volumes and throws on conflicts or failed verification.
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
    [string]$RecoveryRoot,
    [string]$ResticCommand = "restic"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "RakazoPersonal.Common.ps1")

$context = Get-RakazoPersonalCommandContext -DockerContext $DockerContext -DeploymentRoot $DeploymentRoot -RecoveryRoot $RecoveryRoot
$config = Assert-RakazoPersonalInitialized $context
if (-not [IO.Path]::IsPathRooted($DestinationDirectory)) { throw "DestinationDirectory must be absolute." }
$destination = Get-RakazoFullPath $DestinationDirectory
if (Test-Path -LiteralPath $destination) { throw "Retrieval destination already exists: $destination" }
if (-not (Get-Command $ResticCommand -CommandType Application -ErrorAction SilentlyContinue)) { throw "Restic is not installed." }
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
    Invoke-RakazoNativeCommand -FilePath $ResticCommand -ArgumentList @("restore", $snapshot, "--tag", "rakazo-personal", "--target", $destination) | Out-Null
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
New-Item -ItemType Directory -Force -Path $context.ImageSetRoot, $context.RecoveryPointRoot | Out-Null
$recoveredImageRoot = Join-Path $recoveredRoot "image-sets"
foreach ($imageDirectory in @(Get-ChildItem -LiteralPath $recoveredImageRoot -Directory -ErrorAction SilentlyContinue)) {
    [void](Test-RakazoImageArchiveDirectory -Directory $imageDirectory.FullName -ExpectedImageSetId $imageDirectory.Name)
    $localImageDirectory = Join-Path $context.ImageSetRoot $imageDirectory.Name
    if (Test-Path -LiteralPath $localImageDirectory) {
        [void](Test-RakazoImageArchiveDirectory -Directory $localImageDirectory -ExpectedImageSetId $imageDirectory.Name)
        continue
    }
    $paths = New-RakazoAtomicDirectory -Root $context.ImageSetRoot -Name $imageDirectory.Name
    Get-ChildItem -LiteralPath $imageDirectory.FullName -Force | Copy-Item -Destination $paths.Incomplete -Recurse -Force
    Complete-RakazoAtomicDirectory -IncompletePath $paths.Incomplete -FinalPath $paths.Final -AllowedRoot $context.ImageSetRoot
}
foreach ($point in $recoveredPoints) {
    $localPoint = Join-Path $context.RecoveryPointRoot $point.Name
    if (Test-Path -LiteralPath $localPoint) {
        & (Join-Path $PSScriptRoot "Test-RakazoPersonalRecoveryPoint.ps1") -RecoveryPointDirectory $localPoint | Out-Null
        if ((Get-RakazoFileSha256 (Join-Path $localPoint "checksums.sha256")) -ne (Get-RakazoFileSha256 (Join-Path $point.FullName "checksums.sha256"))) {
            throw "A different local recovery point already uses the retrieved name: $($point.Name)"
        }
        continue
    }
    $paths = New-RakazoAtomicDirectory -Root $context.RecoveryPointRoot -Name $point.Name
    Get-ChildItem -LiteralPath $point.FullName -Force | Copy-Item -Destination $paths.Incomplete -Recurse -Force
    & (Join-Path $PSScriptRoot "Test-RakazoPersonalRecoveryPoint.ps1") -RecoveryPointDirectory $paths.Incomplete | Out-Null
    Complete-RakazoAtomicDirectory -IncompletePath $paths.Incomplete -FinalPath $paths.Final -AllowedRoot $context.RecoveryPointRoot
}
Write-Host "Encrypted recovery material retrieved to: $recoveredRoot"
Write-Host "Verified recovery points imported into the local Restore catalogue: $($context.RecoveryPointRoot)"
