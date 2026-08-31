[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ManifestPath,
    [string]$DockerContext = "desktop-linux",
    [string]$OutputDirectory,
    [switch]$KeepArchive
)

<#
.SYNOPSIS
Proves that generated personal images can be recovered from a local Docker archive.

.DESCRIPTION
Saves every image recorded in an image-set manifest, removes only the generated
rakazo-personal app and computer tags, loads the archive, and verifies that every
reference resolves to the original image ID. The test refuses to remove a tag used
by any container and always attempts to reload the archive after a test failure.

.EXAMPLE
.\scripts\windows-ops\tests\Invoke-RakazoImageArchiveRoundTrip.ps1 `
  -ManifestPath '<private-config>\candidate-image-set.json'
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "..\Rakazo.Operations.psm1") -Force

$manifestFile = (Resolve-Path -LiteralPath $ManifestPath).Path
$manifest = Get-Content -Raw -LiteralPath $manifestFile | ConvertFrom-Json
if ($manifest.kind -ne "rakazo-image-set" -or @($manifest.images).Count -eq 0) {
    throw "The supplied file is not a populated Rakazo image-set manifest."
}

$generatedImages = @($manifest.images | Where-Object {
    [string]$_.reference -match '^rakazo-personal/(app|computer):sha-[0-9a-f]{40}$'
})
if ($generatedImages.Count -ne 2) {
    throw "Expected exactly the generated personal app and computer images."
}

foreach ($image in @($manifest.images)) {
    $actual = Get-RakazoImageRecord -DockerContext $DockerContext -Reference ([string]$image.reference)
    if ($actual.id -ne [string]$image.id) {
        throw "Image reference does not match the manifest before archiving: $($image.reference)"
    }
}
foreach ($image in $generatedImages) {
    $containerIds = Get-RakazoDockerOutput -DockerContext $DockerContext -Arguments @(
        "ps", "-a", "--filter", "ancestor=$($image.reference)", "--format", "{{.ID}}"
    )
    if (-not [string]::IsNullOrWhiteSpace($containerIds)) {
        throw "A container uses $($image.reference); refusing to remove its tag for the round-trip test."
    }
}

$createdOutputDirectory = [string]::IsNullOrWhiteSpace($OutputDirectory)
if ($createdOutputDirectory) {
    $OutputDirectory = Join-Path ([IO.Path]::GetTempPath()) "rakazo-image-roundtrip-$([guid]::NewGuid().ToString('N'))"
}
$outputRoot = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Force -Path $outputRoot | Out-Null
$archivePath = Join-Path $outputRoot "rakazo-images.tar"
$removedReferences = [Collections.Generic.List[string]]::new()
$archiveReady = $false

try {
    $references = @($manifest.images | ForEach-Object { [string]$_.reference })
    Invoke-RakazoNativeToFile -FilePath "docker" -ArgumentList (@(
        "--context", $DockerContext, "save"
    ) + $references) -OutputPath $archivePath
    $archiveReady = $true
    Write-Host "Archive created: $archivePath"
    Write-Host "Archive SHA-256: $(Get-RakazoFileSha256 $archivePath)"

    foreach ($image in $generatedImages) {
        Invoke-RakazoDocker -DockerContext $DockerContext -Arguments @(
            "image", "rm", [string]$image.reference
        ) -Quiet | Out-Null
        $removedReferences.Add([string]$image.reference)
    }

    foreach ($reference in $removedReferences) {
        $probe = Invoke-RakazoNativeCommand -FilePath "docker" -ArgumentList @(
            "--context", $DockerContext, "image", "inspect", $reference
        ) -Quiet -AllowFailure
        if ($probe.ExitCode -eq 0) {
            throw "Generated image tag still exists after removal: $reference"
        }
    }

    Invoke-RakazoNativeCommand -FilePath "docker" -ArgumentList @(
        "--context", $DockerContext, "load", "--input", $archivePath
    ) -Quiet | Out-Null
    $removedReferences.Clear()

    foreach ($image in @($manifest.images)) {
        $restored = Get-RakazoImageRecord -DockerContext $DockerContext -Reference ([string]$image.reference)
        if ($restored.id -ne [string]$image.id) {
            throw "Restored image reference has the wrong image ID: $($image.reference)"
        }
    }

    Write-Host "PASS image archive restored every recorded reference without a registry pull."
}
finally {
    if ($removedReferences.Count -gt 0 -and $archiveReady -and (Test-Path -LiteralPath $archivePath)) {
        Write-Warning "The test was interrupted after tag removal; attempting recovery from the archive."
        Invoke-RakazoNativeCommand -FilePath "docker" -ArgumentList @(
            "--context", $DockerContext, "load", "--input", $archivePath
        ) -Quiet -AllowFailure | Out-Null
    }
    if ($createdOutputDirectory -and -not $KeepArchive -and (Test-Path -LiteralPath $outputRoot)) {
        Remove-Item -LiteralPath $outputRoot -Recurse -Force
    }
}
