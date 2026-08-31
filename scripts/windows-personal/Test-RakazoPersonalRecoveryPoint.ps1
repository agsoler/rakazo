[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RecoveryPointDirectory,
    [switch]$AsObject
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "..\windows-ops\Rakazo.Operations.psm1") -Force

$point = (Resolve-Path -LiteralPath $RecoveryPointDirectory).Path
$required = @("rakazo.pgdump", "rakazo-appdata.tar.gz", ".env", "docker-compose.images.yml", "image-set.json", "recovery-point.json", "RECOVERY.txt", "checksums.sha256")
$missing = @($required | Where-Object { -not (Test-Path -LiteralPath (Join-Path $point $_) -PathType Leaf) })
if ($missing.Count) { throw "Incomplete personal recovery point. Missing: $($missing -join ', ')" }
[void](Test-RakazoChecksums -Directory $point)
$manifest = Get-Content -Raw -LiteralPath (Join-Path $point "recovery-point.json") | ConvertFrom-Json
if ($manifest.schemaVersion -ne 1 -or $manifest.kind -ne "rakazo-personal-recovery-point" -or $manifest.project -ne "rakazo-personal") {
    throw "Unsupported or wrong-target recovery-point manifest."
}
$imageSet = Get-Content -Raw -LiteralPath (Join-Path $point "image-set.json") | ConvertFrom-Json
if ($imageSet.kind -ne "rakazo-image-set" -or $imageSet.imageSetId -ne $manifest.imageSetId) {
    throw "Recovery point and image-set manifest do not match."
}
$archive = Get-RakazoFullPath (Join-Path $point $manifest.imageArchive.relativePath)
if (-not (Test-Path -LiteralPath $archive -PathType Leaf)) { throw "Referenced image archive is missing: $archive" }
if ((Get-RakazoFileSha256 $archive) -ne [string]$manifest.imageArchive.sha256) { throw "Image archive checksum mismatch." }
$result = [pscustomobject]@{ Path = $point; Manifest = $manifest; ImageSet = $imageSet; ImageArchive = $archive }
if ($AsObject) { return $result }
Write-Host "Recovery point verified: $point"
Write-Host "Created: $($manifest.createdAt)"
Write-Host "Commit: $($manifest.source.commit)"
Write-Host "Image set: $($manifest.imageSetId)"
