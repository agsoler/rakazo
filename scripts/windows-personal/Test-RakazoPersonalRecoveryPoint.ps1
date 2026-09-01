<#
.SYNOPSIS
Verifies a personal recovery point and its linked image archive.
.DESCRIPTION
Checks required files, checksums, target identity, image-set linkage, archive hash, and archive
size without changing Docker or recovery data. Throws when any check fails.
.EXAMPLE
.\scripts\windows-personal\Test-RakazoPersonalRecoveryPoint.ps1 -RecoveryPointDirectory '<recovery-point>'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RecoveryPointDirectory,
    [switch]$AsObject
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "..\windows-ops\Rakazo.Operations.psm1") -Force

$point = (Resolve-Path -LiteralPath $RecoveryPointDirectory).Path
$manifestPath = Join-Path $point "recovery-point.json"
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "Incomplete personal recovery point. Missing: recovery-point.json"
}
$manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
$required = @("rakazo.pgdump", "rakazo-appdata.tar.gz", ".env", "docker-compose.images.yml", "image-set.json", "recovery-point.json", "RECOVERY.txt", "checksums.sha256")
$readerRoleArtifact = $null
if ($manifest.PSObject.Properties.Name -contains "state" -and
    $null -ne $manifest.state -and
    $manifest.state.PSObject.Properties.Name -contains "readonlyDatabaseRole") {
    $readerRoleArtifact = [string]$manifest.state.readonlyDatabaseRole
    if ($readerRoleArtifact -ne "rakazo-readonly-role.sql") {
        throw "Unsupported read-only database role artifact path."
    }
    $required += $readerRoleArtifact
}
$missing = @($required | Where-Object { -not (Test-Path -LiteralPath (Join-Path $point $_) -PathType Leaf) })
if ($missing.Count) { throw "Incomplete personal recovery point. Missing: $($missing -join ', ')" }
[void](Assert-RakazoRequiredChecksums -Directory $point -RequiredPaths @($required | Where-Object { $_ -ne "checksums.sha256" }))
if ($manifest.schemaVersion -ne 1 -or $manifest.kind -ne "rakazo-personal-recovery-point" -or $manifest.project -ne "rakazo-personal") {
    throw "Unsupported or wrong-target recovery-point manifest."
}
$imageSet = Get-Content -Raw -LiteralPath (Join-Path $point "image-set.json") | ConvertFrom-Json
[void](Assert-RakazoImageSetManifest -Manifest $imageSet -ExpectedImageSetId ([string]$manifest.imageSetId))
$environment = Read-RakazoEnvFile (Join-Path $point ".env")
$expectedReferences = @(
    "$($environment.RAKAZO_IMAGE):$($environment.RAKAZO_IMAGE_TAG)",
    "$($environment.RAKAZO_COMPUTER_IMAGE):$($environment.RAKAZO_COMPUTER_IMAGE_TAG)"
)
$recordedReferences = @($imageSet.images | ForEach-Object { [string]$_.reference })
foreach ($reference in $expectedReferences) {
    if ($reference -match '^:$' -or $reference -notin $recordedReferences) {
        throw "Recovery environment references an image outside its image set: $reference"
    }
}
$pointRoot = Split-Path -Parent $point
if ((Split-Path -Leaf $pointRoot) -ne "recovery-points") { throw "Recovery point is not beneath a recovery-points directory." }
$recoveryRoot = Split-Path -Parent $pointRoot
$archive = Resolve-RakazoContainedPath -BaseDirectory $point -RelativePath ([string]$manifest.imageArchive.relativePath) -AllowedRoot $recoveryRoot -Description "image archive"
$expectedArchive = Join-Path (Join-Path (Join-Path $recoveryRoot "image-sets") ([string]$manifest.imageSetId)) "rakazo-images.tar"
if (-not $archive.Equals((Get-RakazoFullPath $expectedArchive), [StringComparison]::OrdinalIgnoreCase)) {
    throw "Recovery point references an image archive outside its exact image-set directory."
}
$archiveSet = Test-RakazoImageArchiveDirectory -Directory (Split-Path -Parent $archive) -ExpectedImageSetId ([string]$manifest.imageSetId)
if ([string]$archiveSet.Metadata.sha256 -ne [string]$manifest.imageArchive.sha256 -or
    [long]$archiveSet.Metadata.size -ne [long]$manifest.imageArchive.size) {
    throw "Recovery point and image archive metadata do not match."
}
$result = [pscustomobject]@{ Path = $point; Manifest = $manifest; ImageSet = $imageSet; ImageArchive = $archiveSet.Archive }
if ($AsObject) { return $result }
Write-Host "Recovery point verified: $point"
Write-Host "Created: $($manifest.createdAt)"
Write-Host "Commit: $($manifest.source.commit)"
Write-Host "Image set: $($manifest.imageSetId)"
