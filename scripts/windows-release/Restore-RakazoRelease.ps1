[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$DeploymentRoot,
    [Parameter(Mandatory)][string]$BackupRoot,
    [Parameter(Mandatory)][string]$RecoveryPointDirectory,
    [Parameter(Mandatory)][string]$ConfirmationPhrase,
    [string]$Project = "rakazo",
    [string]$DockerContext = "desktop-linux",
    [int]$WebPort = 5200,
    [int]$ApiPort = 3100,
    [switch]$SkipBotTools
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "..\windows-ops\Rakazo.Operations.psm1") -Force

if ($ConfirmationPhrase -cne "RESTORE $Project") { throw "Restore cancelled. Exact confirmation phrase: RESTORE $Project" }
$verified = & (Join-Path $PSScriptRoot "Test-RakazoReleaseRecoveryPoint.ps1") -RecoveryPointDirectory $RecoveryPointDirectory -AsObject
if (-not $verified) { throw "Release recovery verification produced no result." }
$manifestProject = if ($verified.Format -eq "historical") { [string]$verified.Manifest.composeProject } else { [string]$verified.Manifest.project }
if ($manifestProject -and $manifestProject -ne $Project) { throw "Recovery project '$manifestProject' does not match target '$Project'." }

$deployment = Get-RakazoFullPath $DeploymentRoot
New-Item -ItemType Directory -Force -Path $deployment | Out-Null
$envFile = Join-Path $deployment ".env"
$composeFile = Join-Path $deployment "docker-compose.images.yml"
$appDataVolume = "${Project}_appdata"
$postgresVolume = "${Project}_pgdata"
$safetyPoint = "none"
if ((Test-Path -LiteralPath $envFile) -and (Test-Path -LiteralPath $composeFile)) {
    $volumeProbe = Invoke-RakazoNativeCommand -FilePath "docker" -ArgumentList @("--context", $DockerContext, "volume", "inspect", $appDataVolume) -Quiet -AllowFailure
    if ($volumeProbe.ExitCode -eq 0) {
        & (Join-Path $PSScriptRoot "Backup-RakazoRelease.ps1") -DeploymentRoot $deployment -BackupRoot $BackupRoot -Project $Project -DockerContext $DockerContext
        $safetyPoint = (Get-ChildItem -LiteralPath (Join-Path (Get-RakazoFullPath $BackupRoot) "recovery-points") -Directory | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1).FullName
    }
}

Write-Host "Loading the recovery point's exact release images..."
Invoke-RakazoDocker -DockerContext $DockerContext -Arguments @("load", "--input", $verified.ImageArchive) | Out-Null
foreach ($image in @($verified.ImageSet.images)) {
    $expectedId = if ($image.PSObject.Properties.Name -contains "id") { [string]$image.id } else { [string]$image.imageId }
    $actual = Get-RakazoImageRecord -DockerContext $DockerContext -Reference $image.reference
    if ($actual.id -ne $expectedId) { throw "Loaded release image does not match its manifest: $($image.reference)" }
}

$currentComposeArgs = @()
if ((Test-Path -LiteralPath $envFile) -and (Test-Path -LiteralPath $composeFile)) {
    $currentComposeArgs = @("compose", "-p", $Project, "--env-file", $envFile, "-f", $composeFile)
}
$ownedBots = @()
$volumeProbe = Invoke-RakazoNativeCommand -FilePath "docker" -ArgumentList @("--context", $DockerContext, "volume", "inspect", $appDataVolume) -Quiet -AllowFailure
if ($volumeProbe.ExitCode -eq 0) {
    $appDataRoot = Get-RakazoVolumeMountpoint -DockerContext $DockerContext -VolumeName $appDataVolume
    $ownedBots = @(Get-RakazoOwnedBotContainerIds -DockerContext $DockerContext -ExpectedAppDataRoot $appDataRoot -ExpectedProject $Project)
}

try {
    if ($ownedBots.Count) { Invoke-RakazoDocker -DockerContext $DockerContext -Arguments (@("rm", "--force") + $ownedBots) -Quiet | Out-Null }
    if ($currentComposeArgs.Count) { Invoke-RakazoDocker -DockerContext $DockerContext -Arguments ($currentComposeArgs + @("down", "--remove-orphans")) -Quiet | Out-Null }
    foreach ($volume in @($postgresVolume, $appDataVolume)) {
        $probe = Invoke-RakazoNativeCommand -FilePath "docker" -ArgumentList @("--context", $DockerContext, "volume", "inspect", $volume) -Quiet -AllowFailure
        if ($probe.ExitCode -eq 0) { Invoke-RakazoDocker -DockerContext $DockerContext -Arguments @("volume", "rm", $volume) -Quiet | Out-Null }
    }

    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    if (Test-Path $envFile) { Copy-Item $envFile "$envFile.pre-restore-$stamp" }
    if (Test-Path $composeFile) { Copy-Item $composeFile "$composeFile.pre-restore-$stamp" }
    Copy-Item (Join-Path $verified.Path ".env") $envFile -Force
    Copy-Item (Join-Path $verified.Path "docker-compose.images.yml") $composeFile -Force
    $composeArgs = @("compose", "-p", $Project, "--env-file", $envFile, "-f", $composeFile)
    Invoke-RakazoDocker -DockerContext $DockerContext -Arguments ($composeArgs + @("config", "--quiet")) -Quiet | Out-Null
    Invoke-RakazoDocker -DockerContext $DockerContext -Arguments ($composeArgs + @("run", "--rm", "data-init")) -Quiet | Out-Null
    Invoke-RakazoDocker -DockerContext $DockerContext -Arguments @("run", "--rm", "--mount", "source=$appDataVolume,target=/data", "--mount", "type=bind,source=$($verified.Path),target=/backup,readonly", "busybox:1", "sh", "-c", "tar -xzf /backup/rakazo-appdata.tar.gz -C /data && chown -R 1000:1000 /data") -Quiet | Out-Null
    Invoke-RakazoDocker -DockerContext $DockerContext -Arguments ($composeArgs + @("up", "-d", "postgres")) -Quiet | Out-Null
    $ready = $false
    for ($attempt = 0; $attempt -lt 45; $attempt++) {
        $probe = Invoke-RakazoNativeCommand -FilePath "docker" -ArgumentList (@("--context", $DockerContext) + $composeArgs + @("exec", "-T", "postgres", "pg_isready", "-U", "rakazo", "-d", "rakazo")) -Quiet -AllowFailure
        if ($probe.ExitCode -eq 0) { $ready = $true; break }
        Start-Sleep -Seconds 1
    }
    if (-not $ready) { throw "Restored release PostgreSQL did not become ready." }
    $postgresId = Get-RakazoDockerOutput -DockerContext $DockerContext -Arguments ($composeArgs + @("ps", "-q", "postgres"))
    Invoke-RakazoDocker -DockerContext $DockerContext -Arguments @("cp", (Join-Path $verified.Path "rakazo.pgdump"), "${postgresId}:/tmp/rakazo-restore.pgdump") -Quiet | Out-Null
    Invoke-RakazoDocker -DockerContext $DockerContext -Arguments ($composeArgs + @("exec", "-T", "postgres", "pg_restore", "-U", "rakazo", "-d", "rakazo", "--clean", "--if-exists", "--no-owner", "--no-privileges", "/tmp/rakazo-restore.pgdump")) -Quiet | Out-Null
    Invoke-RakazoDocker -DockerContext $DockerContext -Arguments ($composeArgs + @("exec", "-T", "postgres", "rm", "-f", "/tmp/rakazo-restore.pgdump")) -Quiet | Out-Null
    Invoke-RakazoDocker -DockerContext $DockerContext -Arguments ($composeArgs + @("up", "-d")) | Out-Null

    if (-not (Wait-RakazoHttp -Uri "http://127.0.0.1:$ApiPort/health" -TimeoutSeconds 240)) { throw "Restored release API did not become healthy." }
    if (-not (Wait-RakazoHttp -Uri "http://127.0.0.1:$WebPort/" -TimeoutSeconds 240)) { throw "Restored release web UI did not become healthy." }

    $newAppDataRoot = Get-RakazoVolumeMountpoint -DockerContext $DockerContext -VolumeName $appDataVolume
    $newBots = @(Get-RakazoOwnedBotContainerIds -DockerContext $DockerContext -ExpectedAppDataRoot $newAppDataRoot -ExpectedProject $Project -RunningOnly)
    foreach ($botId in $newBots) {
        $networks = Get-RakazoDockerOutput -DockerContext $DockerContext -Arguments @("inspect", "--format", "{{json .NetworkSettings.Networks}}", $botId)
        if ($networks -notmatch [regex]::Escape("${Project}_data")) {
            Invoke-RakazoDocker -DockerContext $DockerContext -Arguments @("network", "connect", "${Project}_data", $botId) -Quiet | Out-Null
        }
        if (-not $SkipBotTools) {
            $tools = Invoke-RakazoNativeCommand -FilePath "docker" -ArgumentList @("--context", $DockerContext, "exec", $botId, "bash", "-lc", "command -v nano >/dev/null && command -v psql >/dev/null") -Quiet -AllowFailure
            if ($tools.ExitCode -ne 0) {
                $install = 'set -e; apt-get update; DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends nano postgresql-client; rm -rf /var/lib/apt/lists/*'
                Invoke-RakazoDocker -DockerContext $DockerContext -Arguments @("exec", "--user", "0", $botId, "bash", "-lc", $install) -Quiet | Out-Null
            }
        }
    }
}
catch {
    Write-Error "Release restore failed. Safety recovery point: $safetyPoint. Failure state retained. $($_.Exception.Message)"
    throw
}
Write-Host "Release restore completed from: $($verified.Path)"
Write-Host "Safety recovery point: $safetyPoint"
