Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:RakazoPersonalRepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$script:RakazoOperationsModule = Join-Path $script:RakazoPersonalRepoRoot "scripts\windows-ops\Rakazo.Operations.psm1"
Import-Module $script:RakazoOperationsModule -Force

function Get-RakazoPersonalContext {
    param(
        [string]$DockerContext = "desktop-linux",
        [string]$DeploymentRoot = (Join-Path $script:RakazoPersonalRepoRoot ".local\personal"),
        [string]$RecoveryRoot = (Join-Path $script:RakazoPersonalRepoRoot ".local\recovery\personal")
    )

    $deployment = Get-RakazoFullPath $DeploymentRoot
    $recovery = Get-RakazoFullPath $RecoveryRoot
    return [pscustomobject]@{
        RepoRoot = $script:RakazoPersonalRepoRoot
        DockerContext = $DockerContext
        Project = "rakazo-personal"
        DeploymentRoot = $deployment
        RecoveryRoot = $recovery
        EnvFile = Join-Path $deployment ".env"
        ComposeFile = Join-Path $deployment "docker-compose.images.yml"
        ConfigFile = Join-Path $deployment "personal-config.json"
        CandidateImageSetFile = Join-Path $deployment "candidate-image-set.json"
        CurrentImageSetFile = Join-Path $deployment "current-image-set.json"
        ImageSetRoot = Join-Path $recovery "image-sets"
        RecoveryPointRoot = Join-Path $recovery "recovery-points"
        LogRoot = Join-Path $deployment "logs"
        AppDataVolume = "rakazo-personal_appdata"
        PostgresVolume = "rakazo-personal_pgdata"
        WebPort = 5400
        ApiPort = 3300
    }
}

function Assert-RakazoPersonalInitialized {
    param([Parameter(Mandatory)]$Context)

    foreach ($path in @($Context.EnvFile, $Context.ComposeFile, $Context.ConfigFile)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Personal stable is not initialized. Missing: $path. Run Initialize-RakazoPersonal.ps1 first."
        }
    }
    $config = Get-Content -Raw -LiteralPath $Context.ConfigFile | ConvertFrom-Json
    if ($config.schemaVersion -ne 1 -or $config.kind -ne "rakazo-personal-config" -or $config.project -ne $Context.Project) {
        throw "Unsupported or wrong-target personal configuration: $($Context.ConfigFile)"
    }
    if ((Get-RakazoFullPath $config.deploymentRoot) -ne $Context.DeploymentRoot) {
        throw "DeploymentRoot does not match the initialized personal configuration."
    }
    return $config
}

function Get-RakazoPersonalComposeArguments {
    param([Parameter(Mandatory)]$Context)

    return @(
        "compose", "-p", $Context.Project,
        "--env-file", $Context.EnvFile,
        "-f", $Context.ComposeFile
    )
}

function Get-RakazoPersonalImageReferences {
    param([Parameter(Mandatory)][string]$EnvFile)

    $envValues = Read-RakazoEnvFile $EnvFile
    $required = @("RAKAZO_IMAGE", "RAKAZO_IMAGE_TAG", "RAKAZO_COMPUTER_IMAGE", "RAKAZO_COMPUTER_IMAGE_TAG")
    foreach ($name in $required) {
        if (-not $envValues.Contains($name) -or [string]::IsNullOrWhiteSpace([string]$envValues[$name])) {
            throw "Missing image setting $name in $EnvFile"
        }
    }
    return @(
        "$($envValues.RAKAZO_IMAGE):$($envValues.RAKAZO_IMAGE_TAG)",
        "$($envValues.RAKAZO_COMPUTER_IMAGE):$($envValues.RAKAZO_COMPUTER_IMAGE_TAG)"
    )
}

function Set-RakazoPersonalImageSet {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$ManifestPath
    )

    $manifest = Get-Content -Raw -LiteralPath $ManifestPath | ConvertFrom-Json
    if ($manifest.kind -ne "rakazo-image-set" -or @($manifest.images).Count -lt 2) {
        throw "Unsupported personal image-set manifest: $ManifestPath"
    }
    $app = @($manifest.images | Where-Object { $_.reference -like "rakazo-personal/app:*" })
    $computer = @($manifest.images | Where-Object { $_.reference -like "rakazo-personal/computer:*" })
    if ($app.Count -ne 1 -or $computer.Count -ne 1) {
        throw "The image set must contain exactly one personal app and one personal computer image."
    }
    $values = Read-RakazoEnvFile $Context.EnvFile
    $values.RAKAZO_IMAGE = "rakazo-personal/app"
    $values.RAKAZO_IMAGE_TAG = ([string]$app[0].reference).Substring("rakazo-personal/app:".Length)
    $values.RAKAZO_COMPUTER_IMAGE = "rakazo-personal/computer"
    $values.RAKAZO_COMPUTER_IMAGE_TAG = ([string]$computer[0].reference).Substring("rakazo-personal/computer:".Length)
    Write-RakazoEnvFile -Values $values -Path $Context.EnvFile
    Copy-Item -LiteralPath $ManifestPath -Destination $Context.CurrentImageSetFile -Force
    Protect-RakazoPrivatePath $Context.EnvFile
}

function Get-RakazoAvailableTcpPort {
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    try { return ([Net.IPEndPoint]$listener.LocalEndpoint).Port }
    finally { $listener.Stop() }
}
