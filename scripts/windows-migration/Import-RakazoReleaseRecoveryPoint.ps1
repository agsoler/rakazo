<#
.SYNOPSIS
Rehearses or applies a one-time migration from a verified release recovery point to personal stable.
.DESCRIPTION
Rehearse restores the selected release point into a generated disposable Docker project, boots its
original images without a worker, upgrades it to the active personal images, and records private
evidence. Apply requires that matching evidence and the exact confirmation phrase exist. Apply
replaces only rakazo-personal database/appdata, leaves the historical source untouched, and leaves
the personal worker stopped until source cutover is approved separately.
.EXAMPLE
.\scripts\windows-migration\Import-RakazoReleaseRecoveryPoint.ps1 -Mode Rehearse -RecoveryPointDirectory '<release-point>'
.EXAMPLE
.\scripts\windows-migration\Import-RakazoReleaseRecoveryPoint.ps1 -Mode Apply -RecoveryPointDirectory '<release-point>' -ConfirmationPhrase 'IMPORT rakazo INTO rakazo-personal'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet("Rehearse", "Apply")][string]$Mode,
    [Parameter(Mandatory)][string]$RecoveryPointDirectory,
    [string]$ConfirmationPhrase = "",
    [string]$DockerContext = "desktop-linux",
    [string]$DeploymentRoot,
    [string]$RecoveryRoot,
    [ValidateRange(30, 600)][int]$TimeoutSeconds = 240,
    [switch]$KeepRehearsalOnFailure
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "RakazoMigration.Common.ps1")

function Get-EndpointSnapshot {
    param([Parameter(Mandatory)][hashtable]$Endpoints)
    $snapshot = [ordered]@{}
    foreach ($entry in $Endpoints.GetEnumerator()) {
        $healthy = $false
        try {
            $response = Invoke-WebRequest -UseBasicParsing -Uri $entry.Value -TimeoutSec 5
            $healthy = $response.StatusCode -ge 200 -and $response.StatusCode -lt 400
        }
        catch { $healthy = $false }
        $snapshot[$entry.Key] = $healthy
    }
    return $snapshot
}

function Assert-EndpointSnapshotUnchanged {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Before,
        [Parameter(Mandatory)][System.Collections.IDictionary]$After
    )
    foreach ($name in $Before.Keys) {
        if ([bool]$Before[$name] -ne [bool]$After[$name]) {
            throw "Unrelated endpoint health changed during migration rehearsal: $name"
        }
    }
}

function Get-SourceIdentityArguments {
    param([Parameter(Mandatory)]$Verified)
    $linkedDirectory = Split-Path -Parent $Verified.ImageArchive
    return @{
        RecoveryPointDirectory = $Verified.Path
        AdditionalFiles = @(Get-ChildItem -LiteralPath $linkedDirectory -File | Select-Object -ExpandProperty FullName)
    }
}

function New-MigrationEnvironment {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Values,
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][int]$WebPort,
        [Parameter(Mandatory)][int]$ApiPort,
        [Parameter(Mandatory)][string]$AppReference,
        [Parameter(Mandatory)][string]$ComputerReference
    )
    $copy = [ordered]@{}
    foreach ($entry in $Values.GetEnumerator()) { $copy[[string]$entry.Key] = [string]$entry.Value }
    $appSeparator = $AppReference.LastIndexOf(':')
    $computerSeparator = $ComputerReference.LastIndexOf(':')
    if ($appSeparator -le $AppReference.LastIndexOf('/') -or $computerSeparator -le $ComputerReference.LastIndexOf('/')) {
        throw "Migration image references must include tags."
    }
    $copy.RAKAZO_IMAGE = $AppReference.Substring(0, $appSeparator)
    $copy.RAKAZO_IMAGE_TAG = $AppReference.Substring($appSeparator + 1)
    $copy.RAKAZO_COMPUTER_IMAGE = $ComputerReference.Substring(0, $computerSeparator)
    $copy.RAKAZO_COMPUTER_IMAGE_TAG = $ComputerReference.Substring($computerSeparator + 1)
    $copy.RAKAZO_DEPLOYMENT_ID = $Project
    $copy.RAKAZO_WEB_PORT = [string]$WebPort
    $copy.RAKAZO_API_PORT = [string]$ApiPort
    $copy.BETTER_AUTH_URL = "http://127.0.0.1:$WebPort"
    $copy.WEB_ORIGIN = "http://127.0.0.1:$WebPort"
    $copy.API_URL = "http://127.0.0.1:$ApiPort"
    $copy.RAKAZO_HOST = "127.0.0.1"
    return $copy
}

function Get-MatchingRehearsalEvidence {
    param(
        [Parameter(Mandatory)][string]$LogRoot,
        [Parameter(Mandatory)][string]$SourceIdentity,
        [Parameter(Mandatory)][string]$SourceImageSetId,
        [Parameter(Mandatory)][string]$TargetImageSetId
    )
    if (-not (Test-Path -LiteralPath $LogRoot -PathType Container)) { return $null }
    foreach ($file in Get-ChildItem -LiteralPath $LogRoot -Filter "migration-rehearsal-*.json" -File | Sort-Object LastWriteTimeUtc -Descending) {
        try {
            $evidence = Get-Content -Raw -LiteralPath $file.FullName | ConvertFrom-Json
            if ($evidence.kind -eq "rakazo-release-migration-rehearsal" -and
                $evidence.status -eq "passed" -and
                [string]$evidence.sourceIdentity -eq $SourceIdentity -and
                [string]$evidence.sourceImageSetId -eq $SourceImageSetId -and
                [string]$evidence.targetImageSetId -eq $TargetImageSetId) {
                return [pscustomobject]@{ Path = $file.FullName; Evidence = $evidence }
            }
        }
        catch { continue }
    }
    return $null
}

$context = Get-RakazoPersonalCommandContext -DockerContext $DockerContext -DeploymentRoot $DeploymentRoot -RecoveryRoot $RecoveryRoot
[void](Assert-RakazoPersonalInitialized $context)
Assert-RakazoPersonalDeploymentIdentity $context
$targetImageSet = Assert-RakazoPersonalActiveImageSet -Context $context -VerifyLocalImages
$verified = & (Join-Path $script:RakazoMigrationRepoRoot "scripts\windows-release\Test-RakazoReleaseRecoveryPoint.ps1") `
    -RecoveryPointDirectory $RecoveryPointDirectory -AsObject
if (-not $verified) { throw "Release recovery verification produced no result." }

$sourceEnvironment = Read-RakazoEnvFile (Join-Path $verified.Path ".env")
$targetEnvironment = Read-RakazoEnvFile $context.EnvFile
$merged = Merge-RakazoReleaseEnvironment -Source $sourceEnvironment -Target $targetEnvironment -ExpectedTargetDeployment $context.Project
$sourceRoles = Get-RakazoMigrationImageRoles -Environment $sourceEnvironment
$targetRoles = Get-RakazoMigrationImageRoles -Environment $targetEnvironment
$sourceImageSetId = Get-RakazoMigrationImageSetId -VerifiedRecoveryPoint $verified
$sourceIdentityArguments = Get-SourceIdentityArguments -Verified $verified
$sourceIdentity = Get-RakazoMigrationSourceIdentity @sourceIdentityArguments
$targetImageSetId = [string]$targetImageSet.imageSetId

Write-Host "Migration preview"
Write-Host "  Mode: $Mode"
Write-Host "  Source format: $($verified.Format)"
Write-Host "  Source image set: $sourceImageSetId"
Write-Host "  Target project: $($context.Project)"
Write-Host "  Target image set: $targetImageSetId"
Write-Host "  Target ports: $($context.WebPort) / $($context.ApiPort)"
Write-Host "  Source-owned settings retained: $($merged.SourceOwnedKeys -join ', ')"
Write-Host "  Deployment settings replaced by personal stable: $($merged.ReplacedSourceKeys -join ', ')"

if ($Mode -eq "Rehearse") {
    $endpointSnapshot = Get-EndpointSnapshot -Endpoints @{
        release = "http://127.0.0.1:5200/"
        development = "http://127.0.0.1:5300/"
        personal = "http://127.0.0.1:5400/"
    }
    Import-RakazoHistoricalImageArchive -DockerContext $DockerContext -VerifiedRecoveryPoint $verified

    $runId = [Guid]::NewGuid().ToString('N').Substring(0, 10)
    # This value is also the custom supervisor deployment ID, whose contract is at most 32 chars.
    $project = "rakazo-mig-$runId"
    $workRoot = Join-Path $script:RakazoMigrationRepoRoot ".local\migration\$project"
    $envPath = Join-Path $workRoot ".env"
    $composePath = Join-Path $workRoot "docker-compose.images.yml"
    $webPort = Get-RakazoAvailableTcpPort
    $apiPort = Get-RakazoAvailableTcpPort
    $composeArguments = @("compose", "-p", $project, "--env-file", $envPath, "-f", $composePath)
    $appDataVolume = "${project}_appdata"
    $complete = $false

    New-Item -ItemType Directory -Force -Path $workRoot, $context.LogRoot | Out-Null
    Protect-RakazoPrivatePath $workRoot
    try {
        $baselineEnvironment = New-MigrationEnvironment -Values $merged.Values -Project $project -WebPort $webPort -ApiPort $apiPort `
            -AppReference $sourceRoles.App -ComputerReference $sourceRoles.Computer
        Write-RakazoEnvFile -Values $baselineEnvironment -Path $envPath
        Protect-RakazoPrivatePath $envPath
        # Use the current port-parameterised wiring so the disposable baseline cannot collide with
        # the live release. The application and computer images remain the exact archived release.
        Copy-Item -LiteralPath $context.ComposeFile -Destination $composePath
        Invoke-RakazoDocker -DockerContext $DockerContext -Arguments ($composeArguments + @("config", "--quiet")) -Quiet | Out-Null

        Write-Host "Restoring the selected source into disposable project $project ..."
        Restore-RakazoMigrationState -DockerContext $DockerContext -ComposeArguments $composeArguments `
            -RecoveryPointDirectory $verified.Path -AppDataVolume $appDataVolume `
            -DatabaseUser $merged.Values.POSTGRES_USER -DatabaseName $merged.Values.POSTGRES_DB
        Invoke-RakazoDocker -DockerContext $DockerContext -Arguments ($composeArguments + @("up", "-d", "postgres", "supervisor", "api", "web")) | Out-Null
        if (-not (Wait-RakazoHttp -Uri "http://127.0.0.1:$apiPort/health" -TimeoutSeconds $TimeoutSeconds)) {
            throw "The disposable release API did not become healthy."
        }
        if (-not (Wait-RakazoHttp -Uri "http://127.0.0.1:$webPort/" -TimeoutSeconds $TimeoutSeconds)) {
            throw "The disposable release web UI did not become healthy."
        }
        $baselineFingerprint = Get-RakazoMigrationFingerprint -DockerContext $DockerContext -ComposeArguments $composeArguments `
            -AppDataVolume $appDataVolume -DatabaseUser $merged.Values.POSTGRES_USER -DatabaseName $merged.Values.POSTGRES_DB

        Write-Host "Upgrading the disposable copy to the active personal image set ..."
        $upgradeEnvironment = New-MigrationEnvironment -Values $merged.Values -Project $project -WebPort $webPort -ApiPort $apiPort `
            -AppReference $targetRoles.App -ComputerReference $targetRoles.Computer
        Write-RakazoEnvFile -Values $upgradeEnvironment -Path $envPath
        Copy-Item -LiteralPath $context.ComposeFile -Destination $composePath -Force
        Invoke-RakazoDocker -DockerContext $DockerContext -Arguments ($composeArguments + @("config", "--quiet")) -Quiet | Out-Null
        Invoke-RakazoDocker -DockerContext $DockerContext -Arguments ($composeArguments + @(
            "up", "-d", "--force-recreate", "postgres", "supervisor", "api", "web"
        )) | Out-Null
        if (-not (Wait-RakazoHttp -Uri "http://127.0.0.1:$apiPort/health" -TimeoutSeconds $TimeoutSeconds)) {
            throw "The upgraded disposable API did not become healthy."
        }
        if (-not (Wait-RakazoHttp -Uri "http://127.0.0.1:$webPort/" -TimeoutSeconds $TimeoutSeconds)) {
            throw "The upgraded disposable web UI did not become healthy."
        }
        $upgradedFingerprint = Get-RakazoMigrationFingerprint -DockerContext $DockerContext -ComposeArguments $composeArguments `
            -AppDataVolume $appDataVolume -DatabaseUser $merged.Values.POSTGRES_USER -DatabaseName $merged.Values.POSTGRES_DB
        Compare-RakazoMigrationFingerprint -Expected $baselineFingerprint -Actual $upgradedFingerprint

        $sourceIdentityAfter = Get-RakazoMigrationSourceIdentity @sourceIdentityArguments
        if ($sourceIdentityAfter -ne $sourceIdentity) { throw "The source recovery material changed during rehearsal." }
        $evidence = [ordered]@{
            schemaVersion = 1
            kind = "rakazo-release-migration-rehearsal"
            status = "passed"
            completedAt = [DateTime]::UtcNow.ToString("o")
            sourceIdentity = $sourceIdentity
            sourceImageSetId = $sourceImageSetId
            targetImageSetId = $targetImageSetId
            targetCommit = [string]$targetImageSet.source.commit
            fingerprint = $upgradedFingerprint
            workerStarted = $false
        }
        $evidencePath = Join-Path $context.LogRoot "migration-rehearsal-$($sourceIdentity.Substring(0, 12))-$($targetImageSetId.Substring([Math]::Max(0, $targetImageSetId.Length - 12))).json"
        Write-RakazoJsonFile -Value $evidence -Path $evidencePath
        Protect-RakazoPrivatePath $evidencePath
        $complete = $true
        Write-Host "Migration rehearsal passed. Private evidence: $evidencePath"
    }
    finally {
        if ($complete -or -not $KeepRehearsalOnFailure) {
            $cleanup = Invoke-RakazoNativeCommand -FilePath "docker" -ArgumentList (@("--context", $DockerContext) + $composeArguments + @(
                "down", "--volumes", "--remove-orphans"
            )) -Quiet -AllowFailure
            if ($cleanup.ExitCode -eq 0 -and (Test-Path -LiteralPath $workRoot)) {
                Assert-RakazoSafeChildPath -Path $workRoot -AllowedRoot (Join-Path $script:RakazoMigrationRepoRoot ".local\migration") -Description "migration rehearsal directory"
                Remove-Item -LiteralPath $workRoot -Recurse -Force
            }
            elseif ($cleanup.ExitCode -ne 0) {
                Write-Warning "Disposable Docker cleanup failed; its working directory was retained: $workRoot"
                if ($complete) { throw "Migration rehearsal passed, but its disposable Docker cleanup failed." }
            }
        }
        else {
            Write-Warning "Failed rehearsal retained for diagnosis: $workRoot"
        }
    }
    $afterSnapshot = Get-EndpointSnapshot -Endpoints @{
        release = "http://127.0.0.1:5200/"
        development = "http://127.0.0.1:5300/"
        personal = "http://127.0.0.1:5400/"
    }
    Assert-EndpointSnapshotUnchanged -Before $endpointSnapshot -After $afterSnapshot
    Write-Host "Release, development, and personal endpoint health remained unchanged."
    return
}

$matchingEvidence = Get-MatchingRehearsalEvidence -LogRoot $context.LogRoot -SourceIdentity $sourceIdentity `
    -SourceImageSetId $sourceImageSetId -TargetImageSetId $targetImageSetId
if (-not $matchingEvidence) {
    throw "No passing rehearsal exists for this exact source and target image set. Run -Mode Rehearse first."
}
$expectedPhrase = "IMPORT rakazo INTO rakazo-personal"
if ([string]::IsNullOrWhiteSpace($ConfirmationPhrase)) {
    $ConfirmationPhrase = Read-Host "Type $expectedPhrase to replace personal state"
}
if ($ConfirmationPhrase -cne $expectedPhrase) {
    throw "Import cancelled. The exact confirmation phrase is: $expectedPhrase"
}

Write-Host "Creating a verified safety recovery point for current personal state ..."
& (Join-Path $script:RakazoMigrationRepoRoot "scripts\windows-personal\Backup-RakazoPersonal.ps1") `
    -DockerContext $DockerContext -DeploymentRoot $context.DeploymentRoot -RecoveryRoot $context.RecoveryRoot -SkipReplication
$safetyPoint = (Get-ChildItem -LiteralPath $context.RecoveryPointRoot -Directory | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1).FullName
& (Join-Path $script:RakazoMigrationRepoRoot "scripts\windows-personal\Test-RakazoPersonalRecoveryPoint.ps1") `
    -RecoveryPointDirectory $safetyPoint | Out-Null

$releaseBefore = Get-EndpointSnapshot -Endpoints @{
    release = "http://127.0.0.1:5200/"
    development = "http://127.0.0.1:5300/"
}
$composeArguments = Get-RakazoPersonalComposeArguments $context
$ownedBots = @()
$appVolumeProbe = Invoke-RakazoNativeCommand -FilePath "docker" -ArgumentList @(
    "--context", $DockerContext, "volume", "inspect", $context.AppDataVolume
) -Quiet -AllowFailure
if ($appVolumeProbe.ExitCode -eq 0) {
    [void](Assert-RakazoDockerVolumeOwnership -DockerContext $DockerContext -VolumeName $context.AppDataVolume -ExpectedProject $context.Project -ExpectedVolume "appdata")
    $appDataRoot = Get-RakazoVolumeMountpoint -DockerContext $DockerContext -VolumeName $context.AppDataVolume
    $ownedBots = @(Get-RakazoOwnedBotContainerIds -DockerContext $DockerContext -ExpectedAppDataRoot $appDataRoot -ExpectedProject $context.Project)
}

try {
    if ($ownedBots.Count) {
        Invoke-RakazoDocker -DockerContext $DockerContext -Arguments (@("rm", "--force") + $ownedBots) -Quiet | Out-Null
    }
    Invoke-RakazoDocker -DockerContext $DockerContext -Arguments ($composeArguments + @("down", "--remove-orphans")) -Quiet | Out-Null
    foreach ($volume in @(
        [pscustomobject]@{ Name = $context.PostgresVolume; Logical = "pgdata" },
        [pscustomobject]@{ Name = $context.AppDataVolume; Logical = "appdata" }
    )) {
        $probe = Invoke-RakazoNativeCommand -FilePath "docker" -ArgumentList @("--context", $DockerContext, "volume", "inspect", $volume.Name) -Quiet -AllowFailure
        if ($probe.ExitCode -eq 0) {
            [void](Assert-RakazoDockerVolumeOwnership -DockerContext $DockerContext -VolumeName $volume.Name -ExpectedProject $context.Project -ExpectedVolume $volume.Logical)
            Invoke-RakazoDocker -DockerContext $DockerContext -Arguments @("volume", "rm", $volume.Name) -Quiet | Out-Null
        }
    }

    Write-RakazoEnvFile -Values $merged.Values -Path $context.EnvFile
    Protect-RakazoPrivatePath $context.EnvFile
    Copy-Item -LiteralPath (Join-Path $script:RakazoMigrationRepoRoot "infra\compose\docker-compose.images.yml") -Destination $context.ComposeFile -Force
    $composeArguments = Get-RakazoPersonalComposeArguments $context
    Invoke-RakazoDocker -DockerContext $DockerContext -Arguments ($composeArguments + @("config", "--quiet")) -Quiet | Out-Null
    Restore-RakazoMigrationState -DockerContext $DockerContext -ComposeArguments $composeArguments `
        -RecoveryPointDirectory $verified.Path -AppDataVolume $context.AppDataVolume `
        -DatabaseUser $merged.Values.POSTGRES_USER -DatabaseName $merged.Values.POSTGRES_DB
    Invoke-RakazoDocker -DockerContext $DockerContext -Arguments ($composeArguments + @("up", "-d", "postgres", "supervisor", "api", "web")) -Quiet | Out-Null
    if (-not (Wait-RakazoHttp -Uri "http://127.0.0.1:$($context.ApiPort)/health" -TimeoutSeconds $TimeoutSeconds)) {
        throw "Imported personal API did not become healthy."
    }
    if (-not (Wait-RakazoHttp -Uri "http://127.0.0.1:$($context.WebPort)/" -TimeoutSeconds $TimeoutSeconds)) {
        throw "Imported personal web UI did not become healthy."
    }
    $actualFingerprint = Get-RakazoMigrationFingerprint -DockerContext $DockerContext -ComposeArguments $composeArguments `
        -AppDataVolume $context.AppDataVolume -DatabaseUser $merged.Values.POSTGRES_USER -DatabaseName $merged.Values.POSTGRES_DB
    Compare-RakazoMigrationFingerprint -Expected $matchingEvidence.Evidence.fingerprint -Actual $actualFingerprint
    if ((Get-RakazoMigrationSourceIdentity @sourceIdentityArguments) -ne $sourceIdentity) {
        throw "The source recovery material changed during import."
    }
    $releaseAfter = Get-EndpointSnapshot -Endpoints @{
        release = "http://127.0.0.1:5200/"
        development = "http://127.0.0.1:5300/"
    }
    Assert-EndpointSnapshotUnchanged -Before $releaseBefore -After $releaseAfter
    $report = [ordered]@{
        schemaVersion = 1
        kind = "rakazo-release-migration-apply"
        status = "awaiting-cutover"
        completedAt = [DateTime]::UtcNow.ToString("o")
        sourceIdentity = $sourceIdentity
        sourceImageSetId = $sourceImageSetId
        targetImageSetId = $targetImageSetId
        safetyRecoveryPoint = Split-Path -Leaf $safetyPoint
        workerStarted = $false
        fingerprint = $actualFingerprint
    }
    $reportPath = Join-Path $context.LogRoot "migration-apply-$([DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')).json"
    Write-RakazoJsonFile -Value $report -Path $reportPath
    Protect-RakazoPrivatePath $reportPath
}
catch {
    Write-Error "Import stopped. The verified safety point is '$safetyPoint'. The failure state was retained for diagnosis; no automatic rollback was attempted. $($_.Exception.Message)"
    throw
}

Write-Host "Import completed and verified on http://127.0.0.1:$($context.WebPort)/"
Write-Host "The rakazo-personal worker is intentionally stopped until the release cutover is approved."
Write-Host "Release 5200 and development 5300 were not changed."
Write-Host "Safety recovery point: $safetyPoint"
