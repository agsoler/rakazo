<#
.SYNOPSIS
Creates a verified state-and-image recovery point for an image-based release deployment.
.DESCRIPTION
Targets only the explicit Compose project and deployment paths. It briefly quiesces release-owned
services, never overwrites completed recovery points, and throws on ownership or backup failure.
.EXAMPLE
.\scripts\windows-release\Backup-RakazoRelease.ps1 -DeploymentRoot '<deployment>' -BackupRoot '<backup-root>'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$DeploymentRoot,
    [Parameter(Mandatory)][string]$BackupRoot,
    [ValidateSet("rakazo")][string]$Project = "rakazo",
    [string]$DockerContext = "desktop-linux"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "..\windows-ops\Rakazo.Operations.psm1") -Force

$deployment = (Resolve-Path -LiteralPath $DeploymentRoot).Path
$backup = Get-RakazoFullPath $BackupRoot
$envFile = Join-Path $deployment ".env"
$composeFile = Join-Path $deployment "docker-compose.images.yml"
foreach ($path in @($envFile, $composeFile)) { if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Release deployment file missing: $path" } }
if ($Project -notmatch '^[a-z0-9][a-z0-9_-]+$') { throw "Unsafe Compose project name." }
New-Item -ItemType Directory -Force -Path $backup | Out-Null
$pointRoot = Join-Path $backup "recovery-points"
$imageRoot = Join-Path $backup "image-sets"
New-Item -ItemType Directory -Force -Path $pointRoot, $imageRoot | Out-Null
$composeArgs = @("compose", "-p", $Project, "--env-file", $envFile, "-f", $composeFile)
Invoke-RakazoDocker -DockerContext $DockerContext -Arguments ($composeArgs + @("config", "--quiet")) -Quiet | Out-Null
$refsText = Get-RakazoDockerOutput -DockerContext $DockerContext -Arguments ($composeArgs + @("config", "--images"))
$refs = @($refsText -split '\r?\n' | Where-Object { $_ } | Sort-Object -Unique)
if (-not $refs.Count) { throw "Compose produced no release image references." }
$images = @($refs | ForEach-Object { Get-RakazoImageRecord -DockerContext $DockerContext -Reference $_ })
$imageSet = New-RakazoImageSetManifest -Images $images -SourceCommit "published-image"
$releaseEnvironment = Read-RakazoEnvFile $envFile
$imageSet["roles"] = [ordered]@{
    app = "$($releaseEnvironment.RAKAZO_IMAGE):$($releaseEnvironment.RAKAZO_IMAGE_TAG)"
    computer = "$($releaseEnvironment.RAKAZO_COMPUTER_IMAGE):$($releaseEnvironment.RAKAZO_COMPUTER_IMAGE_TAG)"
}
$imageSetDirectory = Join-Path $imageRoot $imageSet.imageSetId
$imageSetPath = Join-Path $imageSetDirectory "image-set.json"
$archivePath = Join-Path $imageSetDirectory "rakazo-images.tar"
$archiveCreated = $false
if (Test-Path -LiteralPath $imageSetDirectory -PathType Container) {
    $archiveSet = Test-RakazoImageArchiveDirectory -Directory $imageSetDirectory -ExpectedImageSetId ([string]$imageSet.imageSetId)
    $archiveMetadata = $archiveSet.Metadata
}
else {
    $imageSetPaths = New-RakazoAtomicDirectory -Root $imageRoot -Name ([string]$imageSet.imageSetId)
    try {
        Write-RakazoJsonFile -Value $imageSet -Path (Join-Path $imageSetPaths.Incomplete "image-set.json")
        $incompleteArchive = Join-Path $imageSetPaths.Incomplete "rakazo-images.tar"
        Invoke-RakazoNativeToFile -FilePath "docker" -ArgumentList (@("--context", $DockerContext, "save") + $refs) -OutputPath $incompleteArchive
        $archiveMetadata = [ordered]@{ schemaVersion = 1; kind = "rakazo-image-archive"; imageSetId = $imageSet.imageSetId; file = "rakazo-images.tar"; sha256 = Get-RakazoFileSha256 $incompleteArchive; size = (Get-Item $incompleteArchive).Length }
        Write-RakazoJsonFile -Value $archiveMetadata -Path (Join-Path $imageSetPaths.Incomplete "archive.json")
        Write-RakazoChecksums -Directory $imageSetPaths.Incomplete -RelativePaths @("image-set.json", "archive.json", "rakazo-images.tar")
        Complete-RakazoAtomicDirectory -IncompletePath $imageSetPaths.Incomplete -FinalPath $imageSetPaths.Final -AllowedRoot $imageRoot
        $archiveCreated = $true
    }
    catch {
        Write-Warning "Incomplete release image archive retained for inspection: $($imageSetPaths.Incomplete)"
        throw
    }
}

$pointName = "rakazo-release-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
$paths = New-RakazoAtomicDirectory -Root $pointRoot -Name $pointName
$appDataVolume = "${Project}_appdata"
[void](Assert-RakazoDockerVolumeOwnership -DockerContext $DockerContext -VolumeName $appDataVolume -ExpectedProject $Project -ExpectedVolume "appdata")
$postgresVolume = "${Project}_pgdata"
[void](Assert-RakazoDockerVolumeOwnership -DockerContext $DockerContext -VolumeName $postgresVolume -ExpectedProject $Project -ExpectedVolume "pgdata")
$appDataRoot = Get-RakazoVolumeMountpoint -DockerContext $DockerContext -VolumeName $appDataVolume
$bots = @(Get-RakazoOwnedBotContainerIds -DockerContext $DockerContext -ExpectedAppDataRoot $appDataRoot -ExpectedProject $Project -RunningOnly)
$wasRunning = -not [string]::IsNullOrWhiteSpace((Get-RakazoDockerOutput -DockerContext $DockerContext -Arguments ($composeArgs + @("ps", "-q"))))
$complete = $false
try {
    if ($bots.Count) { Invoke-RakazoDocker -DockerContext $DockerContext -Arguments (@("stop") + $bots) -Quiet | Out-Null }
    Invoke-RakazoDocker -DockerContext $DockerContext -Arguments ($composeArgs + @("stop", "api", "worker", "web", "supervisor")) -Quiet | Out-Null
    Invoke-RakazoDocker -DockerContext $DockerContext -Arguments ($composeArgs + @("up", "-d", "postgres")) -Quiet | Out-Null
    $ready = $false
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        $probe = Invoke-RakazoNativeCommand -FilePath "docker" -ArgumentList (@("--context", $DockerContext) + $composeArgs + @("exec", "-T", "postgres", "pg_isready", "-U", "rakazo", "-d", "rakazo")) -Quiet -AllowFailure
        if ($probe.ExitCode -eq 0) { $ready = $true; break }
        Start-Sleep -Seconds 1
    }
    if (-not $ready) { throw "Release PostgreSQL did not become ready for backup." }
    Invoke-RakazoNativeToFile -FilePath "docker" -ArgumentList (@("--context", $DockerContext) + $composeArgs + @("exec", "-T", "postgres", "pg_dump", "-U", "rakazo", "-d", "rakazo", "--format=custom", "--no-owner", "--no-privileges")) -OutputPath (Join-Path $paths.Incomplete "rakazo.pgdump")
    Invoke-RakazoDocker -DockerContext $DockerContext -Arguments @("run", "--rm", "--mount", "source=$appDataVolume,target=/data,readonly", "--mount", "type=bind,source=$($paths.Incomplete),target=/backup", "busybox:1", "tar", "-czf", "/backup/rakazo-appdata.tar.gz", "-C", "/data", ".") -Quiet | Out-Null
    Copy-Item $envFile (Join-Path $paths.Incomplete ".env")
    Copy-Item $composeFile (Join-Path $paths.Incomplete "docker-compose.images.yml")
    Copy-Item $imageSetPath (Join-Path $paths.Incomplete "image-set.json")
    $manifest = [ordered]@{
        schemaVersion = 1; kind = "rakazo-release-recovery-point"; createdAt = [DateTime]::UtcNow.ToString("o"); project = $Project; imageSetId = $imageSet.imageSetId
        imageArchive = [ordered]@{ relativePath = [IO.Path]::GetRelativePath($paths.Final, $archivePath).Replace('\', '/'); sha256 = $archiveMetadata.sha256; size = $archiveMetadata.size; capturedThisRun = $archiveCreated }
        state = [ordered]@{ database = "rakazo.pgdump"; appdata = "rakazo-appdata.tar.gz"; environment = ".env"; compose = "docker-compose.images.yml"; imageManifest = "image-set.json" }
    }
    Write-RakazoJsonFile -Value $manifest -Path (Join-Path $paths.Incomplete "recovery-point.json")
    Write-RakazoChecksums -Directory $paths.Incomplete -RelativePaths @("rakazo.pgdump", "rakazo-appdata.tar.gz", ".env", "docker-compose.images.yml", "image-set.json", "recovery-point.json")
    Complete-RakazoAtomicDirectory -IncompletePath $paths.Incomplete -FinalPath $paths.Final -AllowedRoot $pointRoot
    $complete = $true
}
finally {
    if ($wasRunning) { Invoke-RakazoNativeCommand -FilePath "docker" -ArgumentList (@("--context", $DockerContext) + $composeArgs + @("up", "-d")) -Quiet -AllowFailure | Out-Null }
    foreach ($bot in $bots) { Invoke-RakazoNativeCommand -FilePath "docker" -ArgumentList @("--context", $DockerContext, "start", $bot) -Quiet -AllowFailure | Out-Null }
    if (-not $complete -and (Test-Path $paths.Incomplete)) { Write-Warning "Incomplete release recovery point retained: $($paths.Incomplete)" }
}
Write-Host "Release recovery point complete: $($paths.Final)"
Write-Host "Image set: $($imageSet.imageSetId) ($(if ($archiveCreated) { 'archived now' } else { 'existing archive reused' }))"
