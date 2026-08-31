<#
.SYNOPSIS
Replicates local personal recovery material into configured encrypted Restic storage.
.DESCRIPTION
Reads only the local recovery root and writes encrypted repository objects. It does not alter
rakazo-personal state. Throws when Restic, repository access, or password configuration is missing.
.EXAMPLE
.\scripts\windows-personal\Sync-RakazoPersonalBackups.ps1 -RunCheck
#>
[CmdletBinding()]
param(
    [string]$DockerContext = "desktop-linux",
    [string]$DeploymentRoot,
    [string]$RecoveryRoot,
    [switch]$InitializeRepository,
    [switch]$RunCheck
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "RakazoPersonal.Common.ps1")

$context = Get-RakazoPersonalCommandContext -DockerContext $DockerContext -DeploymentRoot $DeploymentRoot -RecoveryRoot $RecoveryRoot
$config = Assert-RakazoPersonalInitialized $context
$repository = [string]$config.nas.repository
$passwordFile = [string]$config.nas.passwordFile
$statePath = Join-Path $context.DeploymentRoot "replication-state.json"
$pointDirectories = @(Get-ChildItem -LiteralPath $context.RecoveryPointRoot -Directory -ErrorAction SilentlyContinue | Where-Object Name -notlike ".*.incomplete" | Sort-Object Name)
if (-not $pointDirectories.Count) { throw "No complete personal recovery points are available to replicate." }
$pointRecords = @($pointDirectories | ForEach-Object {
    $verified = & (Join-Path $PSScriptRoot "Test-RakazoPersonalRecoveryPoint.ps1") -RecoveryPointDirectory $_.FullName -AsObject
    [ordered]@{ recoveryPointId = $_.Name; imageSetId = [string]$verified.Manifest.imageSetId; status = "pending" }
})
$state = [ordered]@{
    schemaVersion = 1
    kind = "rakazo-personal-replication-state"
    status = "pending"
    lastAttemptAt = [DateTime]::UtcNow.ToString("o")
    recoveryPoints = $pointRecords
}
Write-RakazoJsonFile -Value $state -Path $statePath
Protect-RakazoPrivatePath $statePath

$oldRepository = $env:RESTIC_REPOSITORY
$oldPasswordFile = $env:RESTIC_PASSWORD_FILE

try {
    if ([string]::IsNullOrWhiteSpace($repository) -or [string]::IsNullOrWhiteSpace($passwordFile)) {
        throw "NAS replication is not configured. Set repository and passwordFile during initialization."
    }
    if (-not (Get-Command restic -CommandType Application -ErrorAction SilentlyContinue)) {
        throw "Restic is not installed. Local recovery points remain valid but are not off-machine."
    }
    if (-not (Test-Path -LiteralPath $passwordFile -PathType Leaf)) { throw "Restic password file is unavailable." }
    $repoParent = Split-Path -Parent $repository
    if (-not (Test-Path -LiteralPath $repoParent -PathType Container)) { throw "The NAS is unavailable or asleep." }
    if (-not (Test-Path -LiteralPath $repository -PathType Container)) {
        if (-not $InitializeRepository) { throw "Restic repository does not exist. Re-run once with -InitializeRepository after reviewing the destination." }
        New-Item -ItemType Directory -Path $repository | Out-Null
    }
    $env:RESTIC_REPOSITORY = $repository
    $env:RESTIC_PASSWORD_FILE = $passwordFile
    $snapshots = Invoke-RakazoNativeCommand -FilePath "restic" -ArgumentList @("snapshots", "--json") -Quiet -AllowFailure
    if ($snapshots.ExitCode -ne 0) {
        if (-not $InitializeRepository) { throw "The restic repository is not initialized or could not be opened." }
        Invoke-RakazoNativeCommand -FilePath "restic" -ArgumentList @("init") | Out-Null
    }

    $parent = Split-Path -Parent $context.RecoveryRoot
    $leaf = Split-Path -Leaf $context.RecoveryRoot
    $tags = @("--tag", "rakazo-personal")
    foreach ($pointRecord in $pointRecords) {
        $tags += @("--tag", "recovery-point:$($pointRecord.recoveryPointId)")
        $tags += @("--tag", "image-set:$($pointRecord.imageSetId)")
    }
    Push-Location $parent
    try {
        $backupResult = Invoke-RakazoNativeCommand -FilePath "restic" -ArgumentList (@("backup", $leaf, "--json") + $tags) -Quiet
    }
    finally { Pop-Location }

    if ($RunCheck) { Invoke-RakazoNativeCommand -FilePath "restic" -ArgumentList @("check") | Out-Null }
    $summary = @($backupResult.Output | ForEach-Object {
        try { $_ | ConvertFrom-Json -ErrorAction Stop } catch { $null }
    } | Where-Object { $_ -and $_.message_type -eq "summary" } | Select-Object -Last 1)
    if (-not $summary.Count -or [string]::IsNullOrWhiteSpace([string]$summary[0].snapshot_id)) {
        throw "Restic completed without reporting a snapshot ID."
    }
    foreach ($pointRecord in $pointRecords) { $pointRecord.status = "synced"; $pointRecord["snapshotId"] = [string]$summary[0].snapshot_id }
    $state.status = "synced"
    $state["syncedAt"] = [DateTime]::UtcNow.ToString("o")
    $state.recoveryPoints = $pointRecords
    Write-RakazoJsonFile -Value $state -Path $statePath
    Protect-RakazoPrivatePath $statePath
    Write-Host "Personal recovery points replicated to encrypted off-machine storage."
}
catch {
    $state.status = "pending"
    $state["lastError"] = $_.Exception.Message
    Write-RakazoJsonFile -Value $state -Path $statePath
    Protect-RakazoPrivatePath $statePath
    throw
}
finally {
    $env:RESTIC_REPOSITORY = $oldRepository
    $env:RESTIC_PASSWORD_FILE = $oldPasswordFile
}
