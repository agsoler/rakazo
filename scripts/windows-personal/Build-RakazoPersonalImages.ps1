[CmdletBinding()]
param(
    [string]$DockerContext = "desktop-linux",
    [string]$DeploymentRoot,
    [string]$RecoveryRoot,
    [string]$IntegrationRef = "origin/integration/rakazo-dev",
    [switch]$SkipFetch
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "RakazoPersonal.Common.ps1")
$contextArgs = @{ DockerContext = $DockerContext }
if ($DeploymentRoot) { $contextArgs.DeploymentRoot = $DeploymentRoot }
if ($RecoveryRoot) { $contextArgs.RecoveryRoot = $RecoveryRoot }
$context = Get-RakazoPersonalContext @contextArgs
[void](Assert-RakazoPersonalInitialized $context)

if (-not $SkipFetch) {
    Invoke-RakazoNativeCommand -FilePath "git" -ArgumentList @("-C", $context.RepoRoot, "fetch", "origin", "integration/rakazo-dev") | Out-Null
}
$commitResult = Invoke-RakazoNativeCommand -FilePath "git" -ArgumentList @("-C", $context.RepoRoot, "rev-parse", "$IntegrationRef^{commit}") -Quiet
$commit = ($commitResult.Output -join "").Trim()
if ($commit -notmatch '^[0-9a-f]{40}$') { throw "Could not resolve a full pushed integration commit from $IntegrationRef" }

$tag = "sha-$commit"
$appReference = "rakazo-personal/app:$tag"
$computerReference = "rakazo-personal/computer:$tag"
$postgresReference = "postgres:16@sha256:e17e86066e5ef83e0952a9347f5c792b7ece00972e2aa787a6986f471b3dd3d5"
$busyboxReference = "busybox:1"
$worktree = Join-Path ([IO.Path]::GetTempPath()) "rakazo-personal-build-$([Guid]::NewGuid().ToString('N'))"
$worktreeAdded = $false

try {
    Invoke-RakazoNativeCommand -FilePath "git" -ArgumentList @("-C", $context.RepoRoot, "worktree", "add", "--detach", $worktree, $commit) | Out-Null
    $worktreeAdded = $true

    Invoke-RakazoDocker -DockerContext $DockerContext -Arguments @(
        "build", "--build-arg", "GIT_SHA=$commit", "--file", (Join-Path $worktree "infra\compose\Dockerfile"),
        "--tag", $appReference, $worktree
    ) | Out-Null
    Invoke-RakazoDocker -DockerContext $DockerContext -Arguments @(
        "build", "--tag", $computerReference, (Join-Path $worktree "infra\sandboxes\computer")
    ) | Out-Null
    Invoke-RakazoDocker -DockerContext $DockerContext -Arguments @("pull", $postgresReference) | Out-Null
    Invoke-RakazoDocker -DockerContext $DockerContext -Arguments @("pull", $busyboxReference) | Out-Null

    Invoke-RakazoDocker -DockerContext $DockerContext -Arguments @(
        "run", "--rm", "--entrypoint", "sh", $appReference, "-lc",
        "test ! -e /app/.env && test ! -e /app/.local && test ! -e /app/backups"
    ) -Quiet | Out-Null

    $images = @(
        Get-RakazoImageRecord -DockerContext $DockerContext -Reference $appReference
        Get-RakazoImageRecord -DockerContext $DockerContext -Reference $computerReference
        Get-RakazoImageRecord -DockerContext $DockerContext -Reference $postgresReference
        Get-RakazoImageRecord -DockerContext $DockerContext -Reference $busyboxReference
    )
    $manifest = New-RakazoImageSetManifest -Images $images -SourceCommit $commit -SourceBranch "integration/rakazo-dev"
    $manifest["dockerfiles"] = @("infra/compose/Dockerfile", "infra/sandboxes/computer/Dockerfile")
    $imageSetDirectory = Join-Path $context.ImageSetRoot $manifest.imageSetId
    New-Item -ItemType Directory -Force -Path $imageSetDirectory | Out-Null
    $manifestPath = Join-Path $imageSetDirectory "image-set.json"
    Write-RakazoJsonFile -Value $manifest -Path $manifestPath
    $checksumFiles = @("image-set.json")
    if (Test-Path -LiteralPath (Join-Path $imageSetDirectory "archive.json") -PathType Leaf) { $checksumFiles += "archive.json" }
    if (Test-Path -LiteralPath (Join-Path $imageSetDirectory "rakazo-images.tar") -PathType Leaf) { $checksumFiles += "rakazo-images.tar" }
    Write-RakazoChecksums -Directory $imageSetDirectory -RelativePaths $checksumFiles
    Copy-Item -LiteralPath $manifestPath -Destination $context.CandidateImageSetFile -Force

    Write-Host "Custom image set built from pushed integration commit $commit"
    Write-Host "App: $appReference"
    Write-Host "Computer: $computerReference"
    Write-Host "Infrastructure images captured in the set: $postgresReference, $busyboxReference"
    Write-Host "Candidate manifest: $($context.CandidateImageSetFile)"
}
finally {
    if ($worktreeAdded) {
        Invoke-RakazoNativeCommand -FilePath "git" -ArgumentList @("-C", $context.RepoRoot, "worktree", "remove", "--force", $worktree) -Quiet -AllowFailure | Out-Null
    }
}
