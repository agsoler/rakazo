<#
.SYNOPSIS
Restores rakazo-personal from one verified recovery point.
.DESCRIPTION
Destructive to only the rakazo-personal database and appdata volumes. It previews the target,
creates a safety backup when state exists, and requires the exact phrase RESTORE rakazo-personal.
Throws before mutation when verification or confirmation fails.
.EXAMPLE
.\scripts\windows-personal\Restore-RakazoPersonal.ps1 -RecoveryPointDirectory '<recovery-point>' -ConfirmationPhrase 'RESTORE rakazo-personal'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RecoveryPointDirectory,
    [string]$ConfirmationPhrase = "",
    [string]$DockerContext = "desktop-linux",
    [string]$DeploymentRoot,
    [string]$RecoveryRoot,
    [ValidateRange(30, 600)][int]$TimeoutSeconds = 240
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "RakazoPersonal.Common.ps1")

$context = Get-RakazoPersonalCommandContext -DockerContext $DockerContext -DeploymentRoot $DeploymentRoot -RecoveryRoot $RecoveryRoot
[void](Assert-RakazoPersonalInitialized $context)
$verified = & (Join-Path $PSScriptRoot "Test-RakazoPersonalRecoveryPoint.ps1") -RecoveryPointDirectory $RecoveryPointDirectory -AsObject
if (-not $verified) { throw "Recovery-point verification produced no result." }
$verifiedRecoveryRoot = Split-Path -Parent (Split-Path -Parent $verified.Path)
if (-not $verifiedRecoveryRoot.Equals((Get-RakazoFullPath $context.RecoveryRoot), [StringComparison]::OrdinalIgnoreCase)) {
    throw "Recovery point is not inside the configured personal recovery root."
}

Write-Host "Restore preview"
Write-Host "  Target project: $($context.Project)"
Write-Host "  Target ports: $($context.WebPort) / $($context.ApiPort)"
Write-Host "  Recovery point: $($verified.Path)"
Write-Host "  Created: $($verified.Manifest.createdAt)"
Write-Host "  Source commit: $($verified.Manifest.source.commit)"
Write-Host "  Image set: $($verified.Manifest.imageSetId)"

$backupEnv = Read-RakazoEnvFile (Join-Path $verified.Path ".env")
if ([string]$backupEnv.RAKAZO_WEB_PORT -ne [string]$context.WebPort -or [string]$backupEnv.RAKAZO_API_PORT -ne [string]$context.ApiPort) {
    throw "Recovery-point ports do not match the personal target."
}

$safetyPoint = "none (target has no recorded personal deployment)"
if (Test-Path -LiteralPath $context.CurrentImageSetFile -PathType Leaf) {
    Write-Host "Creating a safety recovery point for the current personal state..."
    & (Join-Path $PSScriptRoot "Backup-RakazoPersonal.ps1") -DockerContext $DockerContext -DeploymentRoot $context.DeploymentRoot -RecoveryRoot $context.RecoveryRoot -SkipReplication
    $safetyPoint = (Get-ChildItem -LiteralPath $context.RecoveryPointRoot -Directory | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1).FullName
}

$expectedPhrase = "RESTORE rakazo-personal"
if ([string]::IsNullOrWhiteSpace($ConfirmationPhrase)) {
    $ConfirmationPhrase = Read-Host "Safety backup complete. Type $expectedPhrase to replace personal state"
}
if ($ConfirmationPhrase -cne $expectedPhrase) {
    throw "Restore cancelled. The exact confirmation phrase is: $expectedPhrase"
}

Write-Host "Loading the exact image archive..."
Import-RakazoImageSetArchive -DockerContext $DockerContext -ImageSet $verified.ImageSet -ArchivePath $verified.ImageArchive

$composeArgs = Get-RakazoPersonalComposeArguments $context
$ownedBots = @()
$volumeProbe = Invoke-RakazoNativeCommand -FilePath "docker" -ArgumentList @("--context", $DockerContext, "volume", "inspect", $context.AppDataVolume) -Quiet -AllowFailure
if ($volumeProbe.ExitCode -eq 0) {
    [void](Assert-RakazoDockerVolumeOwnership -DockerContext $DockerContext -VolumeName $context.AppDataVolume -ExpectedProject $context.Project -ExpectedVolume "appdata")
    $appDataRoot = Get-RakazoVolumeMountpoint -DockerContext $DockerContext -VolumeName $context.AppDataVolume
    $ownedBots = @(Get-RakazoOwnedBotContainerIds -DockerContext $DockerContext -ExpectedAppDataRoot $appDataRoot -ExpectedProject $context.Project)
}

try {
    if ($ownedBots.Count) {
        Invoke-RakazoDocker -DockerContext $DockerContext -Arguments (@("rm", "--force") + $ownedBots) -Quiet | Out-Null
    }
    Invoke-RakazoDocker -DockerContext $DockerContext -Arguments ($composeArgs + @("down", "--remove-orphans")) -Quiet | Out-Null

    foreach ($volume in @($context.PostgresVolume, $context.AppDataVolume)) {
        $probe = Invoke-RakazoNativeCommand -FilePath "docker" -ArgumentList @("--context", $DockerContext, "volume", "inspect", $volume) -Quiet -AllowFailure
        if ($probe.ExitCode -eq 0) {
            $logicalName = if ($volume -eq $context.PostgresVolume) { "pgdata" } else { "appdata" }
            [void](Assert-RakazoDockerVolumeOwnership -DockerContext $DockerContext -VolumeName $volume -ExpectedProject $context.Project -ExpectedVolume $logicalName)
            Invoke-RakazoDocker -DockerContext $DockerContext -Arguments @("volume", "rm", $volume) -Quiet | Out-Null
        }
    }

    Copy-Item -LiteralPath (Join-Path $verified.Path ".env") -Destination $context.EnvFile -Force
    Copy-Item -LiteralPath (Join-Path $verified.Path "docker-compose.images.yml") -Destination $context.ComposeFile -Force
    Copy-Item -LiteralPath (Join-Path $verified.Path "image-set.json") -Destination $context.CurrentImageSetFile -Force
    Protect-RakazoPrivatePath $context.EnvFile
    $composeArgs = Get-RakazoPersonalComposeArguments $context
    Invoke-RakazoDocker -DockerContext $DockerContext -Arguments ($composeArgs + @("config", "--quiet")) -Quiet | Out-Null

    Invoke-RakazoDocker -DockerContext $DockerContext -Arguments ($composeArgs + @("run", "--rm", "data-init")) -Quiet | Out-Null
    Invoke-RakazoDocker -DockerContext $DockerContext -Arguments @(
        "run", "--rm",
        "--mount", "source=$($context.AppDataVolume),target=/data",
        "--mount", "type=bind,source=$($verified.Path),target=/backup,readonly",
        "busybox:1", "sh", "-c",
        "tar -xzf /backup/rakazo-appdata.tar.gz -C /data && chown -R 1000:1000 /data"
    ) -Quiet | Out-Null

    Invoke-RakazoDocker -DockerContext $DockerContext -Arguments ($composeArgs + @("up", "-d", "postgres")) -Quiet | Out-Null
    $ready = $false
    for ($attempt = 0; $attempt -lt 45; $attempt++) {
        $probe = Invoke-RakazoNativeCommand -FilePath "docker" -ArgumentList (@("--context", $DockerContext) + $composeArgs + @("exec", "-T", "postgres", "pg_isready", "-U", "rakazo", "-d", "rakazo")) -Quiet -AllowFailure
        if ($probe.ExitCode -eq 0) { $ready = $true; break }
        Start-Sleep -Seconds 1
    }
    if (-not $ready) { throw "Restored PostgreSQL did not become ready." }

    $postgresId = Get-RakazoDockerOutput -DockerContext $DockerContext -Arguments ($composeArgs + @("ps", "-q", "postgres"))
    if ([string]::IsNullOrWhiteSpace($postgresId)) { throw "Restored PostgreSQL container was not found." }
    Invoke-RakazoDocker -DockerContext $DockerContext -Arguments @("cp", (Join-Path $verified.Path "rakazo.pgdump"), "${postgresId}:/tmp/rakazo-restore.pgdump") -Quiet | Out-Null
    Invoke-RakazoDocker -DockerContext $DockerContext -Arguments ($composeArgs + @(
        "exec", "-T", "postgres", "pg_restore", "-U", "rakazo", "-d", "rakazo",
        "--clean", "--if-exists", "--no-owner", "--no-privileges", "/tmp/rakazo-restore.pgdump"
    )) -Quiet | Out-Null
    Invoke-RakazoDocker -DockerContext $DockerContext -Arguments ($composeArgs + @("exec", "-T", "postgres", "rm", "-f", "/tmp/rakazo-restore.pgdump")) -Quiet | Out-Null

    Invoke-RakazoDocker -DockerContext $DockerContext -Arguments ($composeArgs + @("up", "-d")) | Out-Null
    if (-not (Wait-RakazoHttp -Uri "http://127.0.0.1:$($context.ApiPort)/health" -TimeoutSeconds $TimeoutSeconds)) { throw "Restored API did not become healthy." }
    if (-not (Wait-RakazoHttp -Uri "http://127.0.0.1:$($context.WebPort)/" -TimeoutSeconds $TimeoutSeconds)) { throw "Restored web UI did not become healthy." }
}
catch {
    Write-Error "Restore did not complete. Safety recovery point: $safetyPoint. Failure state was retained for diagnosis. $($_.Exception.Message)"
    throw
}

Write-Host "Restore completed successfully from: $($verified.Path)"
Write-Host "Safety recovery point: $safetyPoint"
Write-Host "Verify sign-in, bots, groups, conversations, files, and one disposable model interaction."
