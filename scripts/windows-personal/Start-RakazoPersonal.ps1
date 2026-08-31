[CmdletBinding()]
param(
    [string]$DockerContext = "desktop-linux",
    [string]$DeploymentRoot,
    [string]$RecoveryRoot,
    [ValidateRange(30, 600)][int]$TimeoutSeconds = 180
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "RakazoPersonal.Common.ps1")

$contextArgs = @{ DockerContext = $DockerContext }
if ($DeploymentRoot) { $contextArgs.DeploymentRoot = $DeploymentRoot }
if ($RecoveryRoot) { $contextArgs.RecoveryRoot = $RecoveryRoot }
$context = Get-RakazoPersonalContext @contextArgs
[void](Assert-RakazoPersonalInitialized $context)
if (-not (Test-Path -LiteralPath $context.CurrentImageSetFile -PathType Leaf)) {
    throw "No tested personal image set is active. Run Update-RakazoPersonal.ps1 first."
}
$currentImageSet = Get-Content -Raw -LiteralPath $context.CurrentImageSetFile | ConvertFrom-Json
foreach ($image in @($currentImageSet.images)) {
    $actual = Get-RakazoImageRecord -DockerContext $DockerContext -Reference $image.reference
    if ($actual.id -ne $image.id) { throw "Local runtime image does not match the active manifest: $($image.reference)" }
}
$composeArgs = Get-RakazoPersonalComposeArguments $context
Invoke-RakazoDocker -DockerContext $DockerContext -Arguments ($composeArgs + @("config", "--quiet")) -Quiet | Out-Null
Invoke-RakazoDocker -DockerContext $DockerContext -Arguments ($composeArgs + @("up", "-d")) | Out-Null

if (-not (Wait-RakazoHttp -Uri "http://127.0.0.1:$($context.ApiPort)/health" -TimeoutSeconds $TimeoutSeconds)) {
    throw "Personal API did not become healthy on port $($context.ApiPort)."
}
if (-not (Wait-RakazoHttp -Uri "http://127.0.0.1:$($context.WebPort)/" -TimeoutSeconds $TimeoutSeconds)) {
    throw "Personal web UI did not become healthy on port $($context.WebPort)."
}
Write-Host "Rakazo personal stable is running: http://127.0.0.1:$($context.WebPort)"
