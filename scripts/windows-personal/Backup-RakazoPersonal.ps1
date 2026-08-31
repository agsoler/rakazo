<#
.SYNOPSIS
Creates a verified state recovery point for the rakazo-personal deployment.
.DESCRIPTION
Briefly quiesces only rakazo-personal, saves database and appdata state, and archives the exact
image set when needed. Existing recovery points are never overwritten. Throws on failure.
.EXAMPLE
.\scripts\windows-personal\Backup-RakazoPersonal.ps1
#>
[CmdletBinding()]
param(
    [string]$DockerContext = "desktop-linux",
    [string]$DeploymentRoot,
    [string]$RecoveryRoot,
    [switch]$SkipReplication
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "RakazoPersonal.Common.ps1")

$context = Get-RakazoPersonalCommandContext -DockerContext $DockerContext -DeploymentRoot $DeploymentRoot -RecoveryRoot $RecoveryRoot
$config = Assert-RakazoPersonalInitialized $context
$imageSet = Assert-RakazoPersonalActiveImageSet -Context $context -VerifyLocalImages
$imageRefs = @($imageSet.images | ForEach-Object { [string]$_.reference })

New-Item -ItemType Directory -Force -Path $context.ImageSetRoot, $context.RecoveryPointRoot | Out-Null
$imageSetDirectory = Join-Path $context.ImageSetRoot $imageSet.imageSetId
$archivePath = Join-Path $imageSetDirectory "rakazo-images.tar"
$capturedImages = $false
if (Test-Path -LiteralPath $imageSetDirectory -PathType Container) {
    $archiveSet = Test-RakazoImageArchiveDirectory -Directory $imageSetDirectory -ExpectedImageSetId ([string]$imageSet.imageSetId)
    $archiveMetadata = $archiveSet.Metadata
}
else {
    $imageSetPaths = New-RakazoAtomicDirectory -Root $context.ImageSetRoot -Name ([string]$imageSet.imageSetId)
    try {
        Copy-Item -LiteralPath $context.CurrentImageSetFile -Destination (Join-Path $imageSetPaths.Incomplete "image-set.json")
        $incompleteArchive = Join-Path $imageSetPaths.Incomplete "rakazo-images.tar"
        Invoke-RakazoNativeToFile -FilePath "docker" -ArgumentList (@("--context", $DockerContext, "save") + $imageRefs) -OutputPath $incompleteArchive
        $archiveMetadata = [ordered]@{
            schemaVersion = 1
            kind = "rakazo-image-archive"
            imageSetId = [string]$imageSet.imageSetId
            file = "rakazo-images.tar"
            sha256 = Get-RakazoFileSha256 $incompleteArchive
            size = (Get-Item -LiteralPath $incompleteArchive).Length
        }
        Write-RakazoJsonFile -Value $archiveMetadata -Path (Join-Path $imageSetPaths.Incomplete "archive.json")
        Write-RakazoChecksums -Directory $imageSetPaths.Incomplete -RelativePaths @("image-set.json", "archive.json", "rakazo-images.tar")
        Complete-RakazoAtomicDirectory -IncompletePath $imageSetPaths.Incomplete -FinalPath $imageSetPaths.Final -AllowedRoot $context.ImageSetRoot
        $capturedImages = $true
    }
    catch {
        Write-Warning "Incomplete image archive retained for inspection: $($imageSetPaths.Incomplete)"
        throw
    }
}

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$pointName = "rakazo-personal-$timestamp-$(([string]$imageSet.source.commit).Substring(0, 8))"
$paths = New-RakazoAtomicDirectory -Root $context.RecoveryPointRoot -Name $pointName
$composeArgs = Get-RakazoPersonalComposeArguments $context
$composePs = Get-RakazoDockerOutput -DockerContext $DockerContext -Arguments ($composeArgs + @("ps", "-q"))
$wasRunning = -not [string]::IsNullOrWhiteSpace($composePs)
$postgresStartedForBackup = $false
$stoppedBots = @()
$complete = $false

try {
    [void](Assert-RakazoDockerVolumeOwnership -DockerContext $DockerContext -VolumeName $context.AppDataVolume -ExpectedProject $context.Project -ExpectedVolume "appdata")
    [void](Assert-RakazoDockerVolumeOwnership -DockerContext $DockerContext -VolumeName $context.PostgresVolume -ExpectedProject $context.Project -ExpectedVolume "pgdata")
    $appDataRoot = Get-RakazoVolumeMountpoint -DockerContext $DockerContext -VolumeName $context.AppDataVolume
    $stoppedBots = @(Get-RakazoOwnedBotContainerIds -DockerContext $DockerContext -ExpectedAppDataRoot $appDataRoot -ExpectedProject $context.Project -RunningOnly)
    if ($stoppedBots.Count) {
        Invoke-RakazoDocker -DockerContext $DockerContext -Arguments (@("stop") + $stoppedBots) -Quiet | Out-Null
    }
    Invoke-RakazoDocker -DockerContext $DockerContext -Arguments ($composeArgs + @("stop", "api", "worker", "web", "supervisor")) -Quiet | Out-Null
    Invoke-RakazoDocker -DockerContext $DockerContext -Arguments ($composeArgs + @("up", "-d", "postgres")) -Quiet | Out-Null
    $postgresStartedForBackup = $true

    $ready = $false
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        $probe = Invoke-RakazoNativeCommand -FilePath "docker" -ArgumentList (@("--context", $DockerContext) + $composeArgs + @("exec", "-T", "postgres", "pg_isready", "-U", "rakazo", "-d", "rakazo")) -Quiet -AllowFailure
        if ($probe.ExitCode -eq 0) { $ready = $true; break }
        Start-Sleep -Seconds 1
    }
    if (-not $ready) { throw "Personal PostgreSQL did not become ready for backup." }

    $dumpPath = Join-Path $paths.Incomplete "rakazo.pgdump"
    Invoke-RakazoNativeToFile -FilePath "docker" -ArgumentList (@(
        "--context", $DockerContext
    ) + $composeArgs + @(
        "exec", "-T", "postgres", "pg_dump", "-U", "rakazo", "-d", "rakazo",
        "--format=custom", "--no-owner", "--no-privileges"
    )) -OutputPath $dumpPath

    Invoke-RakazoDocker -DockerContext $DockerContext -Arguments @(
        "run", "--rm",
        "--mount", "source=$($context.AppDataVolume),target=/data,readonly",
        "--mount", "type=bind,source=$($paths.Incomplete),target=/backup",
        "busybox:1", "tar", "-czf", "/backup/rakazo-appdata.tar.gz", "-C", "/data", "."
    ) -Quiet | Out-Null
    Copy-Item -LiteralPath $context.EnvFile -Destination (Join-Path $paths.Incomplete ".env")
    Copy-Item -LiteralPath $context.ComposeFile -Destination (Join-Path $paths.Incomplete "docker-compose.images.yml")
    Copy-Item -LiteralPath $context.CurrentImageSetFile -Destination (Join-Path $paths.Incomplete "image-set.json")

    $manifest = [ordered]@{
        schemaVersion = 1
        kind = "rakazo-personal-recovery-point"
        createdAt = [DateTime]::UtcNow.ToString("o")
        project = $context.Project
        source = $imageSet.source
        imageSetId = [string]$imageSet.imageSetId
        imageArchive = [ordered]@{
            relativePath = [IO.Path]::GetRelativePath($paths.Final, $archivePath).Replace('\', '/')
            sha256 = [string]$archiveMetadata.sha256
            size = [long]$archiveMetadata.size
            capturedThisRun = $capturedImages
        }
        state = [ordered]@{
            database = "rakazo.pgdump"
            appdata = "rakazo-appdata.tar.gz"
            environment = ".env"
            compose = "docker-compose.images.yml"
            imageManifest = "image-set.json"
        }
        environment = [ordered]@{ webPort = $context.WebPort; apiPort = $context.ApiPort }
    }
    Write-RakazoJsonFile -Value $manifest -Path (Join-Path $paths.Incomplete "recovery-point.json")
    @"
RAKAZO PERSONAL STABLE RECOVERY POINT

This directory contains private data and secrets. Keep it encrypted.

Image set: $($imageSet.imageSetId)
Source commit: $($imageSet.source.commit)

Restore only with scripts/windows-personal/Restore-RakazoPersonal.ps1. The restore command verifies
checksums and image identity, creates a safety backup when personal state already exists, and
requires an exact confirmation phrase before replacing database or appdata.
"@ | Set-Content -LiteralPath (Join-Path $paths.Incomplete "RECOVERY.txt") -Encoding utf8
    Write-RakazoChecksums -Directory $paths.Incomplete -RelativePaths @(
        "rakazo.pgdump", "rakazo-appdata.tar.gz", ".env", "docker-compose.images.yml",
        "image-set.json", "recovery-point.json", "RECOVERY.txt"
    )
    Complete-RakazoAtomicDirectory -IncompletePath $paths.Incomplete -FinalPath $paths.Final -AllowedRoot $context.RecoveryPointRoot
    $complete = $true
}
finally {
    if ($wasRunning) {
        try { Invoke-RakazoDocker -DockerContext $DockerContext -Arguments ($composeArgs + @("up", "-d")) -Quiet | Out-Null }
        catch { Write-Warning "Could not restart the personal stack automatically: $($_.Exception.Message)" }
    }
    elseif ($postgresStartedForBackup) {
        Invoke-RakazoNativeCommand -FilePath "docker" -ArgumentList (@("--context", $DockerContext) + $composeArgs + @("stop", "postgres")) -Quiet -AllowFailure | Out-Null
    }
    foreach ($botId in $stoppedBots) {
        Invoke-RakazoNativeCommand -FilePath "docker" -ArgumentList @("--context", $DockerContext, "start", $botId) -Quiet -AllowFailure | Out-Null
    }
    if (-not $complete -and (Test-Path -LiteralPath $paths.Incomplete)) {
        Write-Warning "Incomplete recovery data retained for diagnosis: $($paths.Incomplete)"
    }
}

Write-Host "Recovery point complete: $($paths.Final)"
Write-Host "Image set: $($imageSet.imageSetId) ($(if ($capturedImages) { 'archived now' } else { 'existing archive reused' }))"

if (-not $SkipReplication -and -not [string]::IsNullOrWhiteSpace([string]$config.nas.repository)) {
    try {
        & (Join-Path $PSScriptRoot "Sync-RakazoPersonalBackups.ps1") -DockerContext $DockerContext -DeploymentRoot $context.DeploymentRoot -RecoveryRoot $context.RecoveryRoot
    }
    catch {
        Write-Warning "Local backup is valid, but off-machine replication is pending: $($_.Exception.Message)"
    }
}
