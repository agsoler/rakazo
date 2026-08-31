[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ImageSetManifestPath,
    [string]$DockerContext = "desktop-linux",
    [switch]$KeepOnFailure
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path
Import-Module (Join-Path $repoRoot "scripts\windows-ops\Rakazo.Operations.psm1") -Force
. (Join-Path $repoRoot "scripts\windows-personal\RakazoPersonal.Common.ps1")

$manifestPath = (Resolve-Path -LiteralPath $ImageSetManifestPath).Path
$manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
if ($manifest.kind -ne "rakazo-image-set" -or @($manifest.images).Count -lt 2) {
    throw "Unsupported image-set manifest: $manifestPath"
}
foreach ($image in @($manifest.images)) {
    $actual = Get-RakazoImageRecord -DockerContext $DockerContext -Reference $image.reference
    if ($actual.id -ne $image.id) { throw "Local image does not match manifest: $($image.reference)" }
}

$app = @($manifest.images | Where-Object reference -like "rakazo-personal/app:*")
$computer = @($manifest.images | Where-Object reference -like "rakazo-personal/computer:*")
if ($app.Count -ne 1 -or $computer.Count -ne 1) { throw "Expected one app and one computer image." }

$suffix = [Guid]::NewGuid().ToString("N").Substring(0, 10)
$project = "rakazo-personal-smoke-$suffix"
if ($project -notmatch '^rakazo-personal-smoke-[0-9a-f]{10}$') { throw "Unsafe smoke project name." }
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) $project
$composeFile = Join-Path $tempRoot "docker-compose.images.yml"
$envFile = Join-Path $tempRoot ".env"
$webPort = Get-RakazoAvailableTcpPort
$apiPort = Get-RakazoAvailableTcpPort
New-Item -ItemType Directory -Path $tempRoot | Out-Null
Copy-Item -LiteralPath (Join-Path $repoRoot "infra\compose\docker-compose.images.yml") -Destination $composeFile

$appTag = ([string]$app[0].reference).Substring("rakazo-personal/app:".Length)
$computerTag = ([string]$computer[0].reference).Substring("rakazo-personal/computer:".Length)
$values = [ordered]@{
    POSTGRES_USER = "rakazo"
    POSTGRES_PASSWORD = New-RakazoHexSecret 16
    POSTGRES_DB = "rakazo"
    BETTER_AUTH_SECRET = New-RakazoHexSecret 32
    ENCRYPTION_KEY = New-RakazoHexSecret 32
    SCREEN_PROXY_SECRET = New-RakazoHexSecret 32
    SANDBOX_SUPERVISOR_TOKEN = New-RakazoHexSecret 32
    BETTER_AUTH_URL = "http://127.0.0.1:$webPort"
    WEB_ORIGIN = "http://127.0.0.1:$webPort"
    API_URL = "http://127.0.0.1:$webPort"
    RAKAZO_HOST = "localhost"
    RAKAZO_WEB_PORT = [string]$webPort
    RAKAZO_API_PORT = [string]$apiPort
    SIGNUPS_ENABLED = "false"
    RAKAZO_IMAGE = "rakazo-personal/app"
    RAKAZO_IMAGE_TAG = $appTag
    RAKAZO_COMPUTER_IMAGE = "rakazo-personal/computer"
    RAKAZO_COMPUTER_IMAGE_TAG = $computerTag
    SANDBOX_PROVIDER = "docker"
}
Write-RakazoEnvFile -Values $values -Path $envFile
$composeArgs = @("compose", "-p", $project, "--env-file", $envFile, "-f", $composeFile)
$passed = $false

try {
    Invoke-RakazoDocker -DockerContext $DockerContext -Arguments ($composeArgs + @("config", "--quiet")) -Quiet | Out-Null
    Invoke-RakazoDocker -DockerContext $DockerContext -Arguments ($composeArgs + @("up", "-d")) | Out-Null
    $apiReady = Wait-RakazoHttp -Uri "http://127.0.0.1:$apiPort/health" -TimeoutSeconds 180
    $webReady = Wait-RakazoHttp -Uri "http://127.0.0.1:$webPort/" -TimeoutSeconds 180
    if (-not $apiReady -or -not $webReady) {
        Invoke-RakazoDocker -DockerContext $DockerContext -Arguments ($composeArgs + @("ps")) | Out-Null
        throw "Disposable personal image stack did not become healthy."
    }
    $passed = $true
    Write-Host "Disposable image smoke test passed for $($manifest.imageSetId)."
}
finally {
    if ($passed -or -not $KeepOnFailure) {
        Invoke-RakazoDocker -DockerContext $DockerContext -Arguments ($composeArgs + @("down", "--volumes", "--remove-orphans")) -Quiet | Out-Null
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    else {
        Write-Warning "Smoke resources retained for diagnosis: project $project, files $tempRoot"
    }
}
