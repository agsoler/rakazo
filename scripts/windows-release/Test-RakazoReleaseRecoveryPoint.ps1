<#
.SYNOPSIS
Verifies a current or historical release recovery point without restoring it.
.DESCRIPTION
Checks format, required files, checksums, project metadata, and linked image archives. It performs
no Docker mutation and throws when the point is incomplete, tampered with, or unsupported.
.EXAMPLE
.\scripts\windows-release\Test-RakazoReleaseRecoveryPoint.ps1 -RecoveryPointDirectory '<recovery-point>'
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
$pointRoot = Split-Path -Parent $point
$usesImageSetLayout = (Split-Path -Leaf $pointRoot) -eq "recovery-points"
$backupRoot = if ($usesImageSetLayout) { Split-Path -Parent $pointRoot } else { $pointRoot }
$newManifestPath = Join-Path $point "recovery-point.json"
$oldManifestPath = Join-Path $point "manifest.json"

if (Test-Path -LiteralPath $newManifestPath -PathType Leaf) {
    if (-not $usesImageSetLayout) { throw "Current release recovery point is not beneath a recovery-points directory." }
    $required = @("rakazo.pgdump", "rakazo-appdata.tar.gz", ".env", "docker-compose.images.yml", "image-set.json", "recovery-point.json", "checksums.sha256")
    $missing = @($required | Where-Object { -not (Test-Path -LiteralPath (Join-Path $point $_) -PathType Leaf) })
    if ($missing.Count) { throw "Incomplete release recovery point. Missing: $($missing -join ', ')" }
    [void](Assert-RakazoRequiredChecksums -Directory $point -RequiredPaths @($required | Where-Object { $_ -ne "checksums.sha256" }))
    $manifest = Get-Content -Raw -LiteralPath $newManifestPath | ConvertFrom-Json
    if ($manifest.schemaVersion -ne 1 -or $manifest.kind -ne "rakazo-release-recovery-point" -or $manifest.project -ne "rakazo") { throw "Unsupported or wrong-target release recovery manifest." }
    $imageSet = Get-Content -Raw -LiteralPath (Join-Path $point "image-set.json") | ConvertFrom-Json
    [void](Assert-RakazoImageSetManifest -Manifest $imageSet -ExpectedImageSetId ([string]$manifest.imageSetId))
    $environment = Read-RakazoEnvFile (Join-Path $point ".env")
    $expectedReferences = @(
        "$($environment.RAKAZO_IMAGE):$($environment.RAKAZO_IMAGE_TAG)",
        "$($environment.RAKAZO_COMPUTER_IMAGE):$($environment.RAKAZO_COMPUTER_IMAGE_TAG)"
    )
    $recordedReferences = @($imageSet.images | ForEach-Object { [string]$_.reference })
    foreach ($reference in $expectedReferences) {
        if ($reference -match '^:$' -or $reference -notin $recordedReferences) { throw "Release environment references an image outside its image set: $reference" }
    }
    $archive = Resolve-RakazoContainedPath -BaseDirectory $point -RelativePath ([string]$manifest.imageArchive.relativePath) -AllowedRoot $backupRoot -Description "release image archive"
    $expectedArchive = Join-Path (Join-Path (Join-Path $backupRoot "image-sets") ([string]$manifest.imageSetId)) "rakazo-images.tar"
    if (-not $archive.Equals((Get-RakazoFullPath $expectedArchive), [StringComparison]::OrdinalIgnoreCase)) { throw "Release point references the wrong image-set archive." }
    $archiveSet = Test-RakazoImageArchiveDirectory -Directory (Split-Path -Parent $archive) -ExpectedImageSetId ([string]$manifest.imageSetId)
    if ([string]$archiveSet.Metadata.sha256 -ne [string]$manifest.imageArchive.sha256 -or [long]$archiveSet.Metadata.size -ne [long]$manifest.imageArchive.size) { throw "Release point and archive metadata do not match." }
    $result = [pscustomobject]@{ Path = $point; Format = "current"; Manifest = $manifest; ImageSet = $imageSet; ImageArchive = $archiveSet.Archive }
}
elseif (Test-Path -LiteralPath $oldManifestPath -PathType Leaf) {
    foreach ($name in @("rakazo.pgdump", "rakazo-appdata.tar.gz", ".env", "docker-compose.images.yml", "SHA256SUMS.txt")) {
        if (-not (Test-Path -LiteralPath (Join-Path $point $name) -PathType Leaf)) { throw "Incomplete historical release recovery point. Missing: $name" }
    }
    foreach ($line in Get-Content -LiteralPath (Join-Path $point "SHA256SUMS.txt")) {
        if ($line -notmatch '^(?<hash>[0-9a-fA-F]{64})  (?<name>.+)$') { throw "Malformed historical checksum line: $line" }
        $target = Resolve-RakazoContainedPath -BaseDirectory $point -RelativePath $Matches.name -AllowedRoot $point -Description "historical checksum target"
        if (-not (Test-Path -LiteralPath $target -PathType Leaf)) { throw "Historical checksum target missing: $($Matches.name)" }
        if ((Get-RakazoFileSha256 $target) -ne $Matches.hash.ToLowerInvariant()) { throw "Historical checksum mismatch: $($Matches.name)" }
    }
    $manifest = Get-Content -Raw -LiteralPath $oldManifestPath | ConvertFrom-Json
    if ($manifest.type -ne "rakazo-recovery-point") { throw "Unsupported historical release manifest." }
    $imageSetPath = Resolve-RakazoContainedPath -BaseDirectory $point -RelativePath ([string]$manifest.imageSetManifest) -AllowedRoot $backupRoot -Description "historical image-set manifest"
    if (-not (Test-Path -LiteralPath $imageSetPath -PathType Leaf)) { throw "Historical image-set manifest is missing." }
    $imageSetDirectory = Split-Path -Parent $imageSetPath
    $imageChecksums = Join-Path $imageSetDirectory "SHA256SUMS.txt"
    if (Test-Path -LiteralPath $imageChecksums) {
        foreach ($line in Get-Content -LiteralPath $imageChecksums) {
            if ($line -notmatch '^(?<hash>[0-9a-fA-F]{64})  (?<name>.+)$') { throw "Malformed image-set checksum line: $line" }
            $target = Resolve-RakazoContainedPath -BaseDirectory $imageSetDirectory -RelativePath $Matches.name -AllowedRoot $imageSetDirectory -Description "historical image-set checksum target"
            if (-not (Test-Path -LiteralPath $target -PathType Leaf) -or (Get-RakazoFileSha256 $target) -ne $Matches.hash.ToLowerInvariant()) { throw "Historical image-set checksum failed: $($Matches.name)" }
        }
    }
    $archive = Resolve-RakazoContainedPath -BaseDirectory $point -RelativePath ([string]$manifest.imageArchive) -AllowedRoot $backupRoot -Description "historical image archive"
    if (-not (Test-Path -LiteralPath $archive -PathType Leaf)) { throw "Historical release image archive is missing." }
    if ($manifest.imageArchiveSha256 -and (Get-RakazoFileSha256 $archive) -ne ([string]$manifest.imageArchiveSha256).ToLowerInvariant()) { throw "Historical release image archive checksum mismatch." }
    $imageSet = Get-Content -Raw -LiteralPath $imageSetPath | ConvertFrom-Json
    if (@($imageSet.images).Count -eq 0) { throw "Historical image set contains no images." }
    $result = [pscustomobject]@{ Path = $point; Format = "historical"; Manifest = $manifest; ImageSet = $imageSet; ImageArchive = $archive }
}
else {
    throw "No supported release recovery manifest was found in $point"
}

if ($AsObject) { return $result }
Write-Host "Release recovery point verified: $point"
Write-Host "Format: $($result.Format)"
Write-Host "Image set: $($result.Manifest.imageSetId)"
