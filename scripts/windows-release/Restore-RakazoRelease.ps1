<#
.SYNOPSIS
Restores an image-based Rakazo release from a verified recovery point.
.DESCRIPTION
Destructive to only the explicitly named release project and its validated volumes. Requires the
exact phrase RESTORE followed by the project name, creates a safety backup, and throws on mismatch.
.EXAMPLE
.\scripts\windows-release\Restore-RakazoRelease.ps1 -DeploymentRoot '<deployment>' -BackupRoot '<backup-root>' -RecoveryPointDirectory '<recovery-point>' -ConfirmationPhrase 'RESTORE rakazo'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$DeploymentRoot,
    [Parameter(Mandatory)][string]$BackupRoot,
    [Parameter(Mandatory)][string]$RecoveryPointDirectory,
    [string]$ConfirmationPhrase = "",
    [ValidateSet("rakazo")][string]$Project = "rakazo",
    [string]$DockerContext = "desktop-linux",
    [int]$WebPort = 5200,
    [int]$ApiPort = 3100,
    [switch]$SkipBotTools
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "..\windows-ops\Rakazo.Operations.psm1") -Force

$verified = & (Join-Path $PSScriptRoot "Test-RakazoReleaseRecoveryPoint.ps1") -RecoveryPointDirectory $RecoveryPointDirectory -AsObject
if (-not $verified) { throw "Release recovery verification produced no result." }
$manifestProject = if ($verified.Format -eq "historical") { [string]$verified.Manifest.composeProject } else { [string]$verified.Manifest.project }
if ($manifestProject -and $manifestProject -ne $Project) { throw "Recovery project '$manifestProject' does not match target '$Project'." }

$deployment = Get-RakazoFullPath $DeploymentRoot
$backup = Get-RakazoFullPath $BackupRoot
$verifiedPointParent = Split-Path -Parent $verified.Path
$verifiedBackupRoot = if ((Split-Path -Leaf $verifiedPointParent) -eq "recovery-points") { Split-Path -Parent $verifiedPointParent } else { $verifiedPointParent }
if (-not $verifiedBackupRoot.Equals($backup, [StringComparison]::OrdinalIgnoreCase)) { throw "Recovery point is not inside the supplied release backup root." }
New-Item -ItemType Directory -Force -Path $deployment | Out-Null
$envFile = Join-Path $deployment ".env"
$composeFile = Join-Path $deployment "docker-compose.images.yml"
$appDataVolume = "${Project}_appdata"
$postgresVolume = "${Project}_pgdata"
Write-Host "Restore preview"
Write-Host "  Target project: $Project"
Write-Host "  Target ports: $WebPort / $ApiPort"
Write-Host "  Recovery point: $($verified.Path)"
Write-Host "  Image set: $($verified.Manifest.imageSetId)"
$safetyPoint = "none (target has no release volumes)"
$existingVolumes = @()
foreach ($volume in @(
    [pscustomobject]@{ Name = $postgresVolume; Logical = "pgdata" },
    [pscustomobject]@{ Name = $appDataVolume; Logical = "appdata" }
)) {
    $probe = Invoke-RakazoNativeCommand -FilePath "docker" -ArgumentList @("--context", $DockerContext, "volume", "inspect", $volume.Name) -Quiet -AllowFailure
    if ($probe.ExitCode -eq 0) {
        [void](Assert-RakazoDockerVolumeOwnership -DockerContext $DockerContext -VolumeName $volume.Name -ExpectedProject $Project -ExpectedVolume $volume.Logical)
        $existingVolumes += $volume.Name
    }
}
if ($existingVolumes.Count) {
    if ($existingVolumes.Count -ne 2 -or -not (Test-Path -LiteralPath $envFile -PathType Leaf) -or -not (Test-Path -LiteralPath $composeFile -PathType Leaf)) {
        throw "Existing release state is incomplete and cannot be safety-backed up. No restore changes were made. Repair or preserve the existing volumes before retrying."
    }
    & (Join-Path $PSScriptRoot "Backup-RakazoRelease.ps1") -DeploymentRoot $deployment -BackupRoot $BackupRoot -Project $Project -DockerContext $DockerContext
    $safetyPoint = (Get-ChildItem -LiteralPath (Join-Path (Get-RakazoFullPath $BackupRoot) "recovery-points") -Directory | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1).FullName
}

$expectedPhrase = "RESTORE $Project"
if ([string]::IsNullOrWhiteSpace($ConfirmationPhrase)) { $ConfirmationPhrase = Read-Host "Safety backup complete. Type $expectedPhrase to replace release state" }
if ($ConfirmationPhrase -cne $expectedPhrase) { throw "Restore cancelled. Exact confirmation phrase: $expectedPhrase" }

Write-Host "Loading the recovery point's exact release images..."
if ($verified.Format -eq "current") {
    Import-RakazoImageSetArchive -DockerContext $DockerContext -ImageSet $verified.ImageSet -ArchivePath $verified.ImageArchive
}
else {
    Invoke-RakazoDocker -DockerContext $DockerContext -Arguments @("load", "--input", $verified.ImageArchive) -Quiet | Out-Null
    foreach ($image in @($verified.ImageSet.images)) {
        $expectedId = if ($image.PSObject.Properties.Name -contains "id") { [string]$image.id } else { [string]$image.imageId }
        $actual = Get-RakazoImageRecord -DockerContext $DockerContext -Reference $image.reference
        if ($actual.id -ne $expectedId) { throw "Loaded historical release image does not match its manifest: $($image.reference)" }
    }
}

$currentComposeArgs = @()
if ((Test-Path -LiteralPath $envFile) -and (Test-Path -LiteralPath $composeFile)) {
    $currentComposeArgs = @("compose", "-p", $Project, "--env-file", $envFile, "-f", $composeFile)
}
$ownedBots = @()
$volumeProbe = Invoke-RakazoNativeCommand -FilePath "docker" -ArgumentList @("--context", $DockerContext, "volume", "inspect", $appDataVolume) -Quiet -AllowFailure
if ($volumeProbe.ExitCode -eq 0) {
    [void](Assert-RakazoDockerVolumeOwnership -DockerContext $DockerContext -VolumeName $appDataVolume -ExpectedProject $Project -ExpectedVolume "appdata")
    $appDataRoot = Get-RakazoVolumeMountpoint -DockerContext $DockerContext -VolumeName $appDataVolume
    $ownedBots = @(Get-RakazoOwnedBotContainerIds -DockerContext $DockerContext -ExpectedAppDataRoot $appDataRoot -ExpectedProject $Project)
}

try {
    if ($ownedBots.Count) { Invoke-RakazoDocker -DockerContext $DockerContext -Arguments (@("rm", "--force") + $ownedBots) -Quiet | Out-Null }
    if ($currentComposeArgs.Count) { Invoke-RakazoDocker -DockerContext $DockerContext -Arguments ($currentComposeArgs + @("down", "--remove-orphans")) -Quiet | Out-Null }
    foreach ($volume in @($postgresVolume, $appDataVolume)) {
        $probe = Invoke-RakazoNativeCommand -FilePath "docker" -ArgumentList @("--context", $DockerContext, "volume", "inspect", $volume) -Quiet -AllowFailure
        if ($probe.ExitCode -eq 0) {
            $logicalName = if ($volume -eq $postgresVolume) { "pgdata" } else { "appdata" }
            [void](Assert-RakazoDockerVolumeOwnership -DockerContext $DockerContext -VolumeName $volume -ExpectedProject $Project -ExpectedVolume $logicalName)
            Invoke-RakazoDocker -DockerContext $DockerContext -Arguments @("volume", "rm", $volume) -Quiet | Out-Null
        }
    }

    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    if (Test-Path $envFile) { Copy-Item $envFile "$envFile.pre-restore-$stamp" }
    if (Test-Path $composeFile) { Copy-Item $composeFile "$composeFile.pre-restore-$stamp" }
    Copy-Item (Join-Path $verified.Path ".env") $envFile -Force
    Copy-Item (Join-Path $verified.Path "docker-compose.images.yml") $composeFile -Force
    $composeArgs = @("compose", "-p", $Project, "--env-file", $envFile, "-f", $composeFile)
    Invoke-RakazoDocker -DockerContext $DockerContext -Arguments ($composeArgs + @("config", "--quiet")) -Quiet | Out-Null
    Invoke-RakazoDocker -DockerContext $DockerContext -Arguments ($composeArgs + @("run", "--rm", "data-init")) -Quiet | Out-Null
    Invoke-RakazoDocker -DockerContext $DockerContext -Arguments @("run", "--rm", "--mount", "source=$appDataVolume,target=/data", "--mount", "type=bind,source=$($verified.Path),target=/backup,readonly", "busybox:1", "sh", "-c", "tar -xzf /backup/rakazo-appdata.tar.gz -C /data && chown -R 1000:1000 /data") -Quiet | Out-Null
    Invoke-RakazoDocker -DockerContext $DockerContext -Arguments ($composeArgs + @("up", "-d", "postgres")) -Quiet | Out-Null
    $ready = $false
    for ($attempt = 0; $attempt -lt 45; $attempt++) {
        $probe = Invoke-RakazoNativeCommand -FilePath "docker" -ArgumentList (@("--context", $DockerContext) + $composeArgs + @("exec", "-T", "postgres", "pg_isready", "-U", "rakazo", "-d", "rakazo")) -Quiet -AllowFailure
        if ($probe.ExitCode -eq 0) { $ready = $true; break }
        Start-Sleep -Seconds 1
    }
    if (-not $ready) { throw "Restored release PostgreSQL did not become ready." }
    $postgresId = Get-RakazoDockerOutput -DockerContext $DockerContext -Arguments ($composeArgs + @("ps", "-q", "postgres"))
    Invoke-RakazoDocker -DockerContext $DockerContext -Arguments @("cp", (Join-Path $verified.Path "rakazo.pgdump"), "${postgresId}:/tmp/rakazo-restore.pgdump") -Quiet | Out-Null
    Invoke-RakazoDocker -DockerContext $DockerContext -Arguments ($composeArgs + @("exec", "-T", "postgres", "pg_restore", "-U", "rakazo", "-d", "rakazo", "--clean", "--if-exists", "--no-owner", "--no-privileges", "/tmp/rakazo-restore.pgdump")) -Quiet | Out-Null
    Invoke-RakazoDocker -DockerContext $DockerContext -Arguments ($composeArgs + @("exec", "-T", "postgres", "rm", "-f", "/tmp/rakazo-restore.pgdump")) -Quiet | Out-Null
    Invoke-RakazoDocker -DockerContext $DockerContext -Arguments ($composeArgs + @("up", "-d")) | Out-Null

    if (-not (Wait-RakazoHttp -Uri "http://127.0.0.1:$ApiPort/health" -TimeoutSeconds 240)) { throw "Restored release API did not become healthy." }
    if (-not (Wait-RakazoHttp -Uri "http://127.0.0.1:$WebPort/" -TimeoutSeconds 240)) { throw "Restored release web UI did not become healthy." }

    $newAppDataRoot = Get-RakazoVolumeMountpoint -DockerContext $DockerContext -VolumeName $appDataVolume
    $newBots = @(Get-RakazoOwnedBotContainerIds -DockerContext $DockerContext -ExpectedAppDataRoot $newAppDataRoot -ExpectedProject $Project -RunningOnly)
    foreach ($botId in $newBots) {
        $networks = Get-RakazoDockerOutput -DockerContext $DockerContext -Arguments @("inspect", "--format", "{{json .NetworkSettings.Networks}}", $botId)
        if ($networks -notmatch [regex]::Escape("${Project}_data")) {
            Invoke-RakazoDocker -DockerContext $DockerContext -Arguments @("network", "connect", "${Project}_data", $botId) -Quiet | Out-Null
        }
        if (-not $SkipBotTools) {
            $tools = Invoke-RakazoNativeCommand -FilePath "docker" -ArgumentList @("--context", $DockerContext, "exec", $botId, "bash", "-lc", "command -v nano >/dev/null && command -v psql >/dev/null") -Quiet -AllowFailure
            if ($tools.ExitCode -ne 0) {
                $install = 'set -e; apt-get update; DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends nano postgresql-client; rm -rf /var/lib/apt/lists/*'
                Invoke-RakazoDocker -DockerContext $DockerContext -Arguments @("exec", "--user", "0", $botId, "bash", "-lc", $install) -Quiet | Out-Null
            }
        }
    }
}
catch {
    Write-Error "Release restore failed. Safety recovery point: $safetyPoint. Failure state retained. $($_.Exception.Message)"
    throw
}
Write-Host "Release restore completed from: $($verified.Path)"
Write-Host "Safety recovery point: $safetyPoint"
