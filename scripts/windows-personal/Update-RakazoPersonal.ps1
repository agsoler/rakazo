<#
.SYNOPSIS
Builds, smoke-tests, backs up, and deploys the latest pushed personal-stable images.
.DESCRIPTION
Targets only rakazo-personal. It refuses unverified images or a failed pre-update backup, performs
no automatic destructive rollback, and throws when deployment health verification fails.
.EXAMPLE
.\scripts\windows-personal\Update-RakazoPersonal.ps1
#>
[CmdletBinding()]
param(
    [string]$DockerContext = "desktop-linux",
    [string]$DeploymentRoot,
    [string]$RecoveryRoot,
    [ValidateSet("origin/integration/rakazo-dev")][string]$IntegrationRef = "origin/integration/rakazo-dev",
    [switch]$SkipFetch
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "RakazoPersonal.Common.ps1")

$context = Get-RakazoPersonalCommandContext -DockerContext $DockerContext -DeploymentRoot $DeploymentRoot -RecoveryRoot $RecoveryRoot
[void](Assert-RakazoPersonalInitialized $context)
Set-RakazoPersonalDeploymentIdentity $context

& (Join-Path $PSScriptRoot "Test-RakazoPersonalPrerequisites.ps1") -DockerContext $DockerContext
if ($LASTEXITCODE -ne 0) { throw "Personal stable prerequisites failed." }

$buildArgs = @{
    DockerContext = $DockerContext
    DeploymentRoot = $context.DeploymentRoot
    RecoveryRoot = $context.RecoveryRoot
    IntegrationRef = $IntegrationRef
    SkipFetch = $SkipFetch
}
& (Join-Path $PSScriptRoot "Build-RakazoPersonalImages.ps1") @buildArgs
if (-not (Test-Path -LiteralPath $context.CandidateImageSetFile -PathType Leaf)) { throw "Image build produced no candidate manifest." }
$candidate = Get-Content -Raw -LiteralPath $context.CandidateImageSetFile | ConvertFrom-Json

& (Join-Path $context.RepoRoot "scripts\windows-ops\tests\Invoke-PersonalImageSmokeTest.ps1") `
    -ImageSetManifestPath $context.CandidateImageSetFile -DockerContext $DockerContext

$rollbackPoint = "none (initial deployment)"
if (Test-Path -LiteralPath $context.CurrentImageSetFile -PathType Leaf) {
    & (Join-Path $PSScriptRoot "Backup-RakazoPersonal.ps1") -DockerContext $DockerContext -DeploymentRoot $context.DeploymentRoot -RecoveryRoot $context.RecoveryRoot
    $rollbackPoint = (Get-ChildItem -LiteralPath $context.RecoveryPointRoot -Directory | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1).FullName
}

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$rollbackConfigRoot = Join-Path $context.DeploymentRoot "pre-update-$stamp"
New-Item -ItemType Directory -Path $rollbackConfigRoot | Out-Null
Copy-Item -LiteralPath $context.EnvFile -Destination (Join-Path $rollbackConfigRoot ".env")
Copy-Item -LiteralPath $context.ComposeFile -Destination (Join-Path $rollbackConfigRoot "docker-compose.images.yml")
if (Test-Path -LiteralPath $context.CurrentImageSetFile) {
    Copy-Item -LiteralPath $context.CurrentImageSetFile -Destination (Join-Path $rollbackConfigRoot "current-image-set.json")
}

try {
    Copy-Item -LiteralPath (Join-Path $context.RepoRoot "infra\compose\docker-compose.images.yml") -Destination $context.ComposeFile -Force
    Set-RakazoPersonalImageSet -Context $context -ManifestPath $context.CandidateImageSetFile
    & (Join-Path $PSScriptRoot "Start-RakazoPersonal.ps1") -DockerContext $DockerContext -DeploymentRoot $context.DeploymentRoot -RecoveryRoot $context.RecoveryRoot
}
catch {
    Copy-Item -LiteralPath (Join-Path $rollbackConfigRoot ".env") -Destination $context.EnvFile -Force
    Copy-Item -LiteralPath (Join-Path $rollbackConfigRoot "docker-compose.images.yml") -Destination $context.ComposeFile -Force
    $oldManifest = Join-Path $rollbackConfigRoot "current-image-set.json"
    if (Test-Path -LiteralPath $oldManifest) { Copy-Item -LiteralPath $oldManifest -Destination $context.CurrentImageSetFile -Force }
    Write-Error "Update failed. Previous configuration references were restored, but database migrations are not silently reversed. Confirm rollback from: $rollbackPoint. $($_.Exception.Message)"
    throw
}

$record = [ordered]@{
    schemaVersion = 1
    kind = "rakazo-personal-update"
    completedAt = [DateTime]::UtcNow.ToString("o")
    sourceCommit = [string]$candidate.source.commit
    imageSetId = [string]$candidate.imageSetId
    rollbackPoint = $rollbackPoint
}
Write-RakazoJsonFile -Value $record -Path (Join-Path $context.LogRoot "update-$stamp.json")
Write-Host "Personal stable updated successfully to commit $($candidate.source.commit)."
Write-Host "Rollback point retained: $rollbackPoint"
