<#
.SYNOPSIS
Creates ignored local configuration and secrets for rakazo-personal.
.DESCRIPTION
Initialises project rakazo-personal on ports 5400 and 3300 by default. It does not start containers
or overwrite an existing configuration and throws on unsafe or inconsistent input.
.EXAMPLE
.\scripts\windows-personal\Initialize-RakazoPersonal.ps1
#>
[CmdletBinding()]
param(
    [string]$DockerContext = "desktop-linux",
    [string]$DeploymentRoot,
    [string]$RecoveryRoot,
    [string[]]$Models = @("deepseek-v4-flash:cloud", "qwen3.6:27b"),
    [string]$DefaultModel = "deepseek-v4-flash:cloud",
    [string]$NasRepository = "",
    [string]$ResticPasswordFile = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "RakazoPersonal.Common.ps1")
$context = Get-RakazoPersonalCommandContext -DockerContext $DockerContext -DeploymentRoot $DeploymentRoot -RecoveryRoot $RecoveryRoot

if ($Models.Count -eq 0 -or $DefaultModel -notin $Models) {
    throw "Supply at least one model and make DefaultModel one of those models."
}
if ((Test-Path -LiteralPath $context.EnvFile) -or (Test-Path -LiteralPath $context.ConfigFile)) {
    throw "Personal stable is already initialized at $($context.DeploymentRoot). This command never overwrites it."
}

$trackedCompose = Join-Path $context.RepoRoot "infra\compose\docker-compose.images.yml"
New-Item -ItemType Directory -Force -Path $context.DeploymentRoot, $context.RecoveryRoot, $context.ImageSetRoot, $context.RecoveryPointRoot, $context.LogRoot | Out-Null

$values = [ordered]@{
    POSTGRES_USER = "rakazo"
    POSTGRES_PASSWORD = New-RakazoHexSecret 16
    POSTGRES_DB = "rakazo"
    BETTER_AUTH_SECRET = New-RakazoHexSecret 32
    ENCRYPTION_KEY = New-RakazoHexSecret 32
    SCREEN_PROXY_SECRET = New-RakazoHexSecret 32
    SANDBOX_SUPERVISOR_TOKEN = New-RakazoHexSecret 32
    BETTER_AUTH_URL = "http://127.0.0.1:$($context.WebPort)"
    WEB_ORIGIN = "http://127.0.0.1:$($context.WebPort)"
    API_URL = "http://127.0.0.1:$($context.WebPort)"
    RAKAZO_HOST = "localhost"
    RAKAZO_WEB_PORT = [string]$context.WebPort
    RAKAZO_API_PORT = [string]$context.ApiPort
    SIGNUPS_ENABLED = "true"
    SIGNUP_ALLOWLIST = ""
    RAKAZO_IMAGE = "rakazo-personal/app"
    RAKAZO_IMAGE_TAG = "not-built"
    RAKAZO_COMPUTER_IMAGE = "rakazo-personal/computer"
    RAKAZO_COMPUTER_IMAGE_TAG = "not-built"
    RAKAZO_DEPLOYMENT_ID = $context.Project
    RAKAZO_COMPUTER_EXTRA_NETWORK = "$($context.Project)_data"
    SANDBOX_PROVIDER = "docker"
    RAKAZO_LOCAL_MODELS = $Models -join ","
    RAKAZO_LOCAL_MODELS_URL = "http://host.docker.internal:11434/v1"
    RAKAZO_LOCAL_CONTEXT_WINDOW = "32768"
    RAKAZO_LOCAL_MAX_TOKENS = "4096"
    PI_DEFAULT_PROVIDER = "local"
    PI_DEFAULT_MODEL = $DefaultModel
    OPENROUTER_API_KEY = ""
    COMPOSIO_API_KEY = ""
}
Write-RakazoEnvFile -Values $values -Path $context.EnvFile
Copy-Item -LiteralPath $trackedCompose -Destination $context.ComposeFile

$config = [ordered]@{
    schemaVersion = 1
    kind = "rakazo-personal-config"
    project = $context.Project
    dockerContext = $context.DockerContext
    deploymentRoot = $context.DeploymentRoot
    recoveryRoot = $context.RecoveryRoot
    webPort = $context.WebPort
    apiPort = $context.ApiPort
    integrationRef = "origin/integration/rakazo-dev"
    nas = [ordered]@{
        repository = $NasRepository
        passwordFile = $ResticPasswordFile
    }
}
Write-RakazoJsonFile -Value $config -Path $context.ConfigFile
Protect-RakazoPrivatePath $context.DeploymentRoot
Protect-RakazoPrivatePath $context.RecoveryRoot

Write-Host "Personal stable configuration initialized. No containers were started."
Write-Host "Deployment: $($context.DeploymentRoot)"
Write-Host "Local recovery: $($context.RecoveryRoot)"
Write-Host "Next: run Build-RakazoPersonalImages.ps1, then Update-RakazoPersonal.ps1."
