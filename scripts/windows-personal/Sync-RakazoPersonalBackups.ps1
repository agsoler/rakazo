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

$contextArgs = @{ DockerContext = $DockerContext }
if ($DeploymentRoot) { $contextArgs.DeploymentRoot = $DeploymentRoot }
if ($RecoveryRoot) { $contextArgs.RecoveryRoot = $RecoveryRoot }
$context = Get-RakazoPersonalContext @contextArgs
$config = Assert-RakazoPersonalInitialized $context
$repository = [string]$config.nas.repository
$passwordFile = [string]$config.nas.passwordFile
if ([string]::IsNullOrWhiteSpace($repository) -or [string]::IsNullOrWhiteSpace($passwordFile)) {
    throw "NAS replication is not configured. Set repository and passwordFile during initialization."
}
if (-not (Get-Command restic -CommandType Application -ErrorAction SilentlyContinue)) {
    throw "Restic is not installed. Local recovery points remain valid but are not off-machine."
}
if (-not (Test-Path -LiteralPath $passwordFile -PathType Leaf)) { throw "Restic password file is unavailable." }

$repoParent = Split-Path -Parent $repository
if (-not (Test-Path -LiteralPath $repoParent -PathType Container)) {
    throw "The NAS is unavailable or asleep: $repoParent"
}
if (-not (Test-Path -LiteralPath $repository -PathType Container)) {
    if (-not $InitializeRepository) { throw "Restic repository does not exist. Re-run once with -InitializeRepository after reviewing the destination." }
    New-Item -ItemType Directory -Path $repository | Out-Null
}

$oldRepository = $env:RESTIC_REPOSITORY
$oldPasswordFile = $env:RESTIC_PASSWORD_FILE
$env:RESTIC_REPOSITORY = $repository
$env:RESTIC_PASSWORD_FILE = $passwordFile
$statePath = Join-Path $context.DeploymentRoot "replication-state.json"

try {
    $snapshots = Invoke-RakazoNativeCommand -FilePath "restic" -ArgumentList @("snapshots", "--json") -Quiet -AllowFailure
    if ($snapshots.ExitCode -ne 0) {
        if (-not $InitializeRepository) { throw "The restic repository is not initialized or could not be opened." }
        Invoke-RakazoNativeCommand -FilePath "restic" -ArgumentList @("init") | Out-Null
    }

    $parent = Split-Path -Parent $context.RecoveryRoot
    $leaf = Split-Path -Leaf $context.RecoveryRoot
    Push-Location $parent
    try {
        Invoke-RakazoNativeCommand -FilePath "restic" -ArgumentList @("backup", $leaf, "--tag", "rakazo-personal") | Out-Null
    }
    finally { Pop-Location }

    if ($RunCheck) { Invoke-RakazoNativeCommand -FilePath "restic" -ArgumentList @("check") | Out-Null }
    $state = [ordered]@{
        schemaVersion = 1
        kind = "rakazo-personal-replication-state"
        status = "synced"
        syncedAt = [DateTime]::UtcNow.ToString("o")
        recoveryRoot = $context.RecoveryRoot
    }
    Write-RakazoJsonFile -Value $state -Path $statePath
    Write-Host "Personal recovery points replicated to encrypted off-machine storage."
}
finally {
    $env:RESTIC_REPOSITORY = $oldRepository
    $env:RESTIC_PASSWORD_FILE = $oldPasswordFile
}
