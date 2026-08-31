[CmdletBinding(DefaultParameterSetName = "Latest")]
param(
    [Parameter(ParameterSetName = "Snapshot", Mandatory)][string]$SnapshotId,
    [Parameter(ParameterSetName = "Latest")][switch]$Latest,
    [Parameter(Mandatory)][string]$DestinationDirectory,
    [string]$DockerContext = "desktop-linux",
    [string]$DeploymentRoot,
    [string]$RecoveryRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "RakazoPersonal.Common.ps1")

$contextArgs = @{ DockerContext = $DockerContext }
if ($DeploymentRoot) { $contextArgs.DeploymentRoot = $DeploymentRoot }
if ($RecoveryRoot) { $contextArgs.RecoveryRoot = $RecoveryRoot }
$context = Get-RakazoPersonalContext @contextArgs
$config = Assert-RakazoPersonalInitialized $context
if (-not [IO.Path]::IsPathRooted($DestinationDirectory)) { throw "DestinationDirectory must be absolute." }
$destination = Get-RakazoFullPath $DestinationDirectory
if (Test-Path -LiteralPath $destination) { throw "Retrieval destination already exists: $destination" }
if (-not (Get-Command restic -CommandType Application -ErrorAction SilentlyContinue)) { throw "Restic is not installed." }
$repository = [string]$config.nas.repository
$passwordFile = [string]$config.nas.passwordFile
if (-not (Test-Path -LiteralPath $repository -PathType Container)) { throw "The NAS restic repository is unavailable." }
if (-not (Test-Path -LiteralPath $passwordFile -PathType Leaf)) { throw "Restic password file is unavailable." }

$oldRepository = $env:RESTIC_REPOSITORY
$oldPasswordFile = $env:RESTIC_PASSWORD_FILE
$env:RESTIC_REPOSITORY = $repository
$env:RESTIC_PASSWORD_FILE = $passwordFile
$snapshot = if ($PSCmdlet.ParameterSetName -eq "Latest") { "latest" } else { $SnapshotId }
try {
    Invoke-RakazoNativeCommand -FilePath "restic" -ArgumentList @("restore", $snapshot, "--tag", "rakazo-personal", "--target", $destination) | Out-Null
}
finally {
    $env:RESTIC_REPOSITORY = $oldRepository
    $env:RESTIC_PASSWORD_FILE = $oldPasswordFile
}
$recoveredRoot = Join-Path $destination (Split-Path -Leaf $context.RecoveryRoot)
if (-not (Test-Path -LiteralPath $recoveredRoot -PathType Container)) { throw "Restic restore completed without the expected personal recovery root." }
Write-Host "Encrypted recovery material retrieved to: $recoveredRoot"
