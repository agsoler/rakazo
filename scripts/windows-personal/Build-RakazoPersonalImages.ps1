<#
.SYNOPSIS
Builds immutable personal app and computer images from a pushed integration commit.
.DESCRIPTION
Uses a clean detached worktree and records exact image IDs without starting any deployment.
Targets rakazo-personal image names and throws if the requested Git ref is unsafe or unavailable.
.EXAMPLE
.\scripts\windows-personal\Build-RakazoPersonalImages.ps1
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

if (-not $SkipFetch) {
    Invoke-RakazoNativeCommand -FilePath "git" -ArgumentList @("-C", $context.RepoRoot, "fetch", "origin", "integration/rakazo-dev") | Out-Null
}
$commitResult = Invoke-RakazoNativeCommand -FilePath "git" -ArgumentList @("-C", $context.RepoRoot, "rev-parse", "$IntegrationRef^{commit}") -Quiet
$commit = ($commitResult.Output -join "").Trim()
if ($commit -notmatch '^[0-9a-f]{40}$') { throw "Could not resolve a full pushed integration commit from $IntegrationRef" }
$remoteResult = Invoke-RakazoNativeCommand -FilePath "git" -ArgumentList @(
    "-C", $context.RepoRoot, "ls-remote", "--heads", "origin", "refs/heads/integration/rakazo-dev"
) -Quiet
$remoteCommit = (($remoteResult.Output -join "`n") -split '\s+')[0]
if ($remoteCommit -notmatch '^[0-9a-f]{40}$' -or $remoteCommit -ne $commit) {
    throw "The build ref is not the latest pushed origin/integration/rakazo-dev commit."
}

$tag = "sha-$commit"
$appReference = "rakazo-personal/app:$tag"
$computerReference = "rakazo-personal/computer:$tag"
$buildSuffix = [Guid]::NewGuid().ToString('N')
$temporaryAppReference = "rakazo-personal/build-app:$buildSuffix"
$temporaryComputerReference = "rakazo-personal/build-computer:$buildSuffix"
$postgresReference = "postgres:16@sha256:e17e86066e5ef83e0952a9347f5c792b7ece00972e2aa787a6986f471b3dd3d5"
$busyboxReference = "busybox:1"
$worktree = Join-Path ([IO.Path]::GetTempPath()) "rakazo-personal-build-$([Guid]::NewGuid().ToString('N'))"
$worktreeAdded = $false

try {
    Invoke-RakazoNativeCommand -FilePath "git" -ArgumentList @("-C", $context.RepoRoot, "worktree", "add", "--detach", $worktree, $commit) | Out-Null
    $worktreeAdded = $true

    Invoke-RakazoDocker -DockerContext $DockerContext -Arguments @(
        "build", "--provenance=false", "--build-arg", "GIT_SHA=$commit", "--file", (Join-Path $worktree "infra\compose\Dockerfile"),
        "--tag", $temporaryAppReference, $worktree
    ) | Out-Null
    Invoke-RakazoDocker -DockerContext $DockerContext -Arguments @(
        "build", "--provenance=false", "--tag", $temporaryComputerReference, (Join-Path $worktree "infra\sandboxes\computer")
    ) | Out-Null
    Invoke-RakazoDocker -DockerContext $DockerContext -Arguments @("pull", $postgresReference) | Out-Null
    Invoke-RakazoDocker -DockerContext $DockerContext -Arguments @("pull", $busyboxReference) | Out-Null

    Invoke-RakazoDocker -DockerContext $DockerContext -Arguments @(
        "run", "--rm", "--entrypoint", "sh", $temporaryAppReference, "-lc",
        "test ! -e /app/.env && test ! -e /app/.local && test ! -e /app/backups"
    ) -Quiet | Out-Null

    foreach ($pair in @(
        [pscustomobject]@{ Temporary = $temporaryAppReference; Target = $appReference }
        [pscustomobject]@{ Temporary = $temporaryComputerReference; Target = $computerReference }
    )) {
        $temporary = Get-RakazoImageRecord -DockerContext $DockerContext -Reference $pair.Temporary
        $existingProbe = Invoke-RakazoNativeCommand -FilePath "docker" -ArgumentList @(
            "--context", $DockerContext, "image", "inspect", $pair.Target
        ) -Quiet -AllowFailure
        if ($existingProbe.ExitCode -eq 0) {
            $existing = Get-RakazoImageRecord -DockerContext $DockerContext -Reference $pair.Target
            if ($existing.id -ne $temporary.id) {
                throw "Immutable image tag already exists with different content: $($pair.Target). Build from a new pushed commit."
            }
        }
        else {
            Invoke-RakazoDocker -DockerContext $DockerContext -Arguments @("image", "tag", $pair.Temporary, $pair.Target) -Quiet | Out-Null
        }
    }

    $images = @(
        Get-RakazoImageRecord -DockerContext $DockerContext -Reference $appReference
        Get-RakazoImageRecord -DockerContext $DockerContext -Reference $computerReference
        Get-RakazoImageRecord -DockerContext $DockerContext -Reference $postgresReference
        Get-RakazoImageRecord -DockerContext $DockerContext -Reference $busyboxReference
    )
    $manifest = New-RakazoImageSetManifest -Images $images -SourceCommit $commit -SourceBranch "integration/rakazo-dev"
    $manifest["dockerfiles"] = @("infra/compose/Dockerfile", "infra/sandboxes/computer/Dockerfile")
    $manifest["roles"] = [ordered]@{
        app = $appReference
        computer = $computerReference
        postgres = $postgresReference
        archiveUtility = $busyboxReference
    }
    Write-RakazoJsonFile -Value $manifest -Path $context.CandidateImageSetFile

    Write-Host "Custom image set built from pushed integration commit $commit"
    Write-Host "App: $appReference"
    Write-Host "Computer: $computerReference"
    Write-Host "Infrastructure images captured in the set: $postgresReference, $busyboxReference"
    Write-Host "Candidate manifest: $($context.CandidateImageSetFile)"
}
finally {
    foreach ($temporaryReference in @($temporaryAppReference, $temporaryComputerReference)) {
        Invoke-RakazoNativeCommand -FilePath "docker" -ArgumentList @("--context", $DockerContext, "image", "rm", $temporaryReference) -Quiet -AllowFailure | Out-Null
    }
    if ($worktreeAdded) {
        Invoke-RakazoNativeCommand -FilePath "git" -ArgumentList @("-C", $context.RepoRoot, "worktree", "remove", "--force", $worktree) -Quiet -AllowFailure | Out-Null
    }
}
