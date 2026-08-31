[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RecoveryPointDirectory,
    [switch]$AsObject
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "..\windows-ops\Rakazo.Operations.psm1") -Force

$point = (Resolve-Path -LiteralPath $RecoveryPointDirectory).Path
$newManifestPath = Join-Path $point "recovery-point.json"
$oldManifestPath = Join-Path $point "manifest.json"

if (Test-Path -LiteralPath $newManifestPath -PathType Leaf) {
    $required = @("rakazo.pgdump", "rakazo-appdata.tar.gz", ".env", "docker-compose.images.yml", "image-set.json", "recovery-point.json", "checksums.sha256")
    $missing = @($required | Where-Object { -not (Test-Path -LiteralPath (Join-Path $point $_) -PathType Leaf) })
    if ($missing.Count) { throw "Incomplete release recovery point. Missing: $($missing -join ', ')" }
    [void](Test-RakazoChecksums -Directory $point)
    $manifest = Get-Content -Raw -LiteralPath $newManifestPath | ConvertFrom-Json
    if ($manifest.kind -ne "rakazo-release-recovery-point") { throw "Unsupported release recovery manifest." }
    $imageSet = Get-Content -Raw -LiteralPath (Join-Path $point "image-set.json") | ConvertFrom-Json
    $archive = Get-RakazoFullPath (Join-Path $point $manifest.imageArchive.relativePath)
    if (-not (Test-Path -LiteralPath $archive -PathType Leaf)) { throw "Referenced release image archive is missing." }
    if ((Get-RakazoFileSha256 $archive) -ne [string]$manifest.imageArchive.sha256) { throw "Release image archive checksum mismatch." }
    $result = [pscustomobject]@{ Path = $point; Format = "current"; Manifest = $manifest; ImageSet = $imageSet; ImageArchive = $archive }
}
elseif (Test-Path -LiteralPath $oldManifestPath -PathType Leaf) {
    foreach ($name in @("rakazo.pgdump", "rakazo-appdata.tar.gz", ".env", "docker-compose.images.yml", "SHA256SUMS.txt")) {
        if (-not (Test-Path -LiteralPath (Join-Path $point $name) -PathType Leaf)) { throw "Incomplete historical release recovery point. Missing: $name" }
    }
    foreach ($line in Get-Content -LiteralPath (Join-Path $point "SHA256SUMS.txt")) {
        if ($line -notmatch '^(?<hash>[0-9a-fA-F]{64})  (?<name>.+)$') { throw "Malformed historical checksum line: $line" }
        $target = Join-Path $point $Matches.name
        if (-not (Test-Path -LiteralPath $target -PathType Leaf)) { throw "Historical checksum target missing: $($Matches.name)" }
        if ((Get-RakazoFileSha256 $target) -ne $Matches.hash.ToLowerInvariant()) { throw "Historical checksum mismatch: $($Matches.name)" }
    }
    $manifest = Get-Content -Raw -LiteralPath $oldManifestPath | ConvertFrom-Json
    if ($manifest.type -ne "rakazo-recovery-point") { throw "Unsupported historical release manifest." }
    $imageSetPath = Get-RakazoFullPath (Join-Path $point $manifest.imageSetManifest)
    if (-not (Test-Path -LiteralPath $imageSetPath -PathType Leaf)) { throw "Historical image-set manifest is missing." }
    $imageSetDirectory = Split-Path -Parent $imageSetPath
    $imageChecksums = Join-Path $imageSetDirectory "SHA256SUMS.txt"
    if (Test-Path -LiteralPath $imageChecksums) {
        foreach ($line in Get-Content -LiteralPath $imageChecksums) {
            if ($line -notmatch '^(?<hash>[0-9a-fA-F]{64})  (?<name>.+)$') { throw "Malformed image-set checksum line: $line" }
            $target = Join-Path $imageSetDirectory $Matches.name
            if (-not (Test-Path -LiteralPath $target -PathType Leaf) -or (Get-RakazoFileSha256 $target) -ne $Matches.hash.ToLowerInvariant()) { throw "Historical image-set checksum failed: $($Matches.name)" }
        }
    }
    $archive = Get-RakazoFullPath (Join-Path $point $manifest.imageArchive)
    if (-not (Test-Path -LiteralPath $archive -PathType Leaf)) { throw "Historical release image archive is missing." }
    if ($manifest.imageArchiveSha256 -and (Get-RakazoFileSha256 $archive) -ne ([string]$manifest.imageArchiveSha256).ToLowerInvariant()) { throw "Historical release image archive checksum mismatch." }
    $imageSet = Get-Content -Raw -LiteralPath $imageSetPath | ConvertFrom-Json
    $result = [pscustomobject]@{ Path = $point; Format = "historical"; Manifest = $manifest; ImageSet = $imageSet; ImageArchive = $archive }
}
else {
    throw "No supported release recovery manifest was found in $point"
}

if ($AsObject) { return $result }
Write-Host "Release recovery point verified: $point"
Write-Host "Format: $($result.Format)"
Write-Host "Image set: $($result.Manifest.imageSetId)"
