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

function Get-RakazoPersonalCommandContext {
    param(
        [string]$DockerContext = "desktop-linux",
        [string]$DeploymentRoot = "",
        [string]$RecoveryRoot = ""
    )

    $arguments = @{ DockerContext = $DockerContext }
    if (-not [string]::IsNullOrWhiteSpace($DeploymentRoot)) { $arguments.DeploymentRoot = $DeploymentRoot }
    if (-not [string]::IsNullOrWhiteSpace($RecoveryRoot)) { $arguments.RecoveryRoot = $RecoveryRoot }
    return Get-RakazoPersonalContext @arguments
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

function Set-RakazoPersonalDeploymentIdentity {
    param([Parameter(Mandatory)]$Context)

    $values = Read-RakazoEnvFile $Context.EnvFile
    $configured = if ($values.Contains("RAKAZO_DEPLOYMENT_ID")) { [string]$values.RAKAZO_DEPLOYMENT_ID } else { "" }
    if (-not [string]::IsNullOrWhiteSpace($configured) -and $configured -ne $Context.Project) {
        throw "Personal environment belongs to deployment '$configured', not '$($Context.Project)'."
    }
    if ($configured -ne $Context.Project) {
        $values.RAKAZO_DEPLOYMENT_ID = $Context.Project
        Write-RakazoEnvFile -Values $values -Path $Context.EnvFile
        Protect-RakazoPrivatePath $Context.EnvFile
    }
}

function Assert-RakazoPersonalDeploymentIdentity {
    param([Parameter(Mandatory)]$Context)

    $values = Read-RakazoEnvFile $Context.EnvFile
    if (-not $values.Contains("RAKAZO_DEPLOYMENT_ID") -or [string]$values.RAKAZO_DEPLOYMENT_ID -ne $Context.Project) {
        throw "Personal deployment identity is missing or incorrect. Run Update-RakazoPersonal.ps1 before starting or backing up personal stable."
    }
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

function Assert-RakazoPersonalActiveImageSet {
    param(
        [Parameter(Mandatory)]$Context,
        [switch]$VerifyLocalImages
    )

    if (-not (Test-Path -LiteralPath $Context.CurrentImageSetFile -PathType Leaf)) {
        throw "No tested personal image set is active. Run Update-RakazoPersonal.ps1 first."
    }
    $manifest = Get-Content -Raw -LiteralPath $Context.CurrentImageSetFile | ConvertFrom-Json
    [void](Assert-RakazoImageSetManifest -Manifest $manifest)
    $recordedReferences = @($manifest.images | ForEach-Object { [string]$_.reference })
    foreach ($reference in @(Get-RakazoPersonalImageReferences -EnvFile $Context.EnvFile)) {
        if ($reference -notin $recordedReferences) {
            throw "Personal environment references an image outside the active image set: $reference"
        }
    }
    if ($VerifyLocalImages) {
        foreach ($image in @($manifest.images)) {
            $actual = Get-RakazoImageRecord -DockerContext $Context.DockerContext -Reference $image.reference
            if ($actual.id -ne $image.id) {
                throw "Local runtime image does not match the active manifest: $($image.reference)"
            }
        }
    }
    return $manifest
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
    [void](Assert-RakazoImageSetManifest -Manifest $manifest)
    $references = @($manifest.images | ForEach-Object { [string]$_.reference })
    $legacyApps = @($manifest.images | Where-Object { $_.reference -like "rakazo-personal/app:*" })
    $legacyComputers = @($manifest.images | Where-Object { $_.reference -like "rakazo-personal/computer:*" })
    $appReference = if ($manifest.PSObject.Properties.Name -contains "roles") { [string]$manifest.roles.app } elseif ($legacyApps.Count -eq 1) { [string]$legacyApps[0].reference } else { "" }
    $computerReference = if ($manifest.PSObject.Properties.Name -contains "roles") { [string]$manifest.roles.computer } elseif ($legacyComputers.Count -eq 1) { [string]$legacyComputers[0].reference } else { "" }
    foreach ($reference in @($appReference, $computerReference)) {
        if ([string]::IsNullOrWhiteSpace($reference) -or $reference -notin $references -or $reference -match '@sha256:') {
            throw "The image set must identify tagged app and computer image roles."
        }
    }
    $appSeparator = $appReference.LastIndexOf(':')
    $computerSeparator = $computerReference.LastIndexOf(':')
    if ($appSeparator -le $appReference.LastIndexOf('/') -or $computerSeparator -le $computerReference.LastIndexOf('/')) { throw "App and computer image roles must include tags." }
    $values = Read-RakazoEnvFile $Context.EnvFile
    $values.RAKAZO_IMAGE = $appReference.Substring(0, $appSeparator)
    $values.RAKAZO_IMAGE_TAG = $appReference.Substring($appSeparator + 1)
    $values.RAKAZO_COMPUTER_IMAGE = $computerReference.Substring(0, $computerSeparator)
    $values.RAKAZO_COMPUTER_IMAGE_TAG = $computerReference.Substring($computerSeparator + 1)
    $values.RAKAZO_DEPLOYMENT_ID = $Context.Project
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
