Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:RakazoMigrationRepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
Import-Module (Join-Path $script:RakazoMigrationRepoRoot "scripts\windows-ops\Rakazo.Operations.psm1") -Force
. (Join-Path $script:RakazoMigrationRepoRoot "scripts\windows-personal\RakazoPersonal.Common.ps1")

$script:RakazoReleaseSourceOwnedKeys = @(
    "POSTGRES_USER",
    "POSTGRES_PASSWORD",
    "POSTGRES_DB",
    "BETTER_AUTH_SECRET",
    "ENCRYPTION_KEY",
    "SCREEN_PROXY_SECRET",
    "SANDBOX_SUPERVISOR_TOKEN",
    "SIGNUPS_ENABLED",
    "SIGNUP_ALLOWLIST"
)

$script:RakazoKnownReleaseKeys = @(
    $script:RakazoReleaseSourceOwnedKeys +
    @(
        "BETTER_AUTH_URL",
        "WEB_ORIGIN",
        "API_URL",
        "RAKAZO_HOST",
        "RAKAZO_IMAGE",
        "RAKAZO_IMAGE_TAG",
        "RAKAZO_COMPUTER_IMAGE",
        "RAKAZO_COMPUTER_IMAGE_TAG",
        "SANDBOX_PROVIDER",
        "OLLAMA_HOST"
    )
)

function Merge-RakazoReleaseEnvironment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Source,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Target,
        [string]$ExpectedTargetDeployment = "rakazo-personal"
    )

    $requiredSource = @(
        "POSTGRES_USER", "POSTGRES_PASSWORD", "POSTGRES_DB", "BETTER_AUTH_SECRET",
        "ENCRYPTION_KEY", "SCREEN_PROXY_SECRET", "SANDBOX_SUPERVISOR_TOKEN"
    )
    foreach ($name in $requiredSource) {
        if (-not $Source.Contains($name) -or [string]::IsNullOrWhiteSpace([string]$Source[$name])) {
            throw "The release recovery environment is missing required setting: $name"
        }
    }

    $requiredTarget = @(
        "RAKAZO_DEPLOYMENT_ID", "RAKAZO_WEB_PORT", "RAKAZO_API_PORT",
        "BETTER_AUTH_URL", "WEB_ORIGIN", "API_URL", "RAKAZO_HOST",
        "RAKAZO_IMAGE", "RAKAZO_IMAGE_TAG", "RAKAZO_COMPUTER_IMAGE",
        "RAKAZO_COMPUTER_IMAGE_TAG", "SANDBOX_PROVIDER"
    )
    foreach ($name in $requiredTarget) {
        if (-not $Target.Contains($name) -or [string]::IsNullOrWhiteSpace([string]$Target[$name])) {
            throw "The personal target environment is missing required setting: $name"
        }
    }
    if ([string]$Target.RAKAZO_DEPLOYMENT_ID -cne $ExpectedTargetDeployment) {
        throw "The target environment belongs to '$($Target.RAKAZO_DEPLOYMENT_ID)', not '$ExpectedTargetDeployment'."
    }

    $unknown = @($Source.Keys | Where-Object { [string]$_ -notin $script:RakazoKnownReleaseKeys } | Sort-Object)
    if ($unknown.Count) {
        throw "The release recovery environment contains unclassified setting names: $($unknown -join ', ')"
    }

    $merged = [ordered]@{}
    foreach ($entry in $Target.GetEnumerator()) {
        $merged[[string]$entry.Key] = [string]$entry.Value
    }
    foreach ($name in $script:RakazoReleaseSourceOwnedKeys) {
        if ($Source.Contains($name)) {
            $merged[$name] = [string]$Source[$name]
        }
    }

    $replacedSourceKeys = @($Source.Keys | Where-Object { [string]$_ -notin $script:RakazoReleaseSourceOwnedKeys } | Sort-Object)
    return [pscustomobject]@{
        Values = $merged
        SourceOwnedKeys = @($script:RakazoReleaseSourceOwnedKeys | Where-Object { $Source.Contains($_) })
        ReplacedSourceKeys = $replacedSourceKeys
    }
}

function Get-RakazoMigrationSourceIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RecoveryPointDirectory,
        [string[]]$AdditionalFiles = @()
    )

    $root = (Resolve-Path -LiteralPath $RecoveryPointDirectory).Path
    $lines = foreach ($file in Get-ChildItem -LiteralPath $root -File -Recurse | Sort-Object FullName) {
        $relative = [IO.Path]::GetRelativePath($root, $file.FullName).Replace('\', '/')
        "$relative|$($file.Length)|$(Get-RakazoFileSha256 -Path $file.FullName)"
    }
    $externalIndex = 0
    foreach ($path in @($AdditionalFiles | Sort-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "A linked recovery file is missing." }
        $file = Get-Item -LiteralPath $path
        $externalIndex++
        $lines += "linked-$externalIndex|$($file.Length)|$(Get-RakazoFileSha256 -Path $file.FullName)"
    }
    if (@($lines).Count -eq 0) { throw "The recovery point contains no files." }
    return Get-RakazoStringSha256 -Value ($lines -join "`n")
}

function Get-RakazoMigrationImageSetId {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$VerifiedRecoveryPoint)

    $id = [string]$VerifiedRecoveryPoint.Manifest.imageSetId
    if ([string]::IsNullOrWhiteSpace($id)) { $id = [string]$VerifiedRecoveryPoint.ImageSet.imageSetId }
    if ([string]::IsNullOrWhiteSpace($id)) { throw "The release recovery point has no image-set identity." }
    return $id
}

function Get-RakazoMigrationImageRoles {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Environment)

    foreach ($name in @("RAKAZO_IMAGE", "RAKAZO_IMAGE_TAG", "RAKAZO_COMPUTER_IMAGE", "RAKAZO_COMPUTER_IMAGE_TAG")) {
        if (-not $Environment.Contains($name) -or [string]::IsNullOrWhiteSpace([string]$Environment[$name])) {
            throw "The environment does not identify the required image role: $name"
        }
    }
    return [pscustomobject]@{
        App = "$($Environment.RAKAZO_IMAGE):$($Environment.RAKAZO_IMAGE_TAG)"
        Computer = "$($Environment.RAKAZO_COMPUTER_IMAGE):$($Environment.RAKAZO_COMPUTER_IMAGE_TAG)"
    }
}

function Import-RakazoHistoricalImageArchive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DockerContext,
        [Parameter(Mandatory)]$VerifiedRecoveryPoint
    )

    $needsLoad = $false
    foreach ($image in @($VerifiedRecoveryPoint.ImageSet.images)) {
        try {
            $existing = Get-RakazoImageRecord -DockerContext $DockerContext -Reference ([string]$image.reference)
            $expectedId = if ($image.PSObject.Properties.Name -contains "imageId") { [string]$image.imageId } else { [string]$image.id }
            if ([string]$existing.id -ne $expectedId) { $needsLoad = $true; break }
        }
        catch { $needsLoad = $true; break }
    }
    if ($needsLoad) {
        Invoke-RakazoDocker -DockerContext $DockerContext -Arguments @("load", "--input", $VerifiedRecoveryPoint.ImageArchive) -Quiet | Out-Null
    }
    foreach ($image in @($VerifiedRecoveryPoint.ImageSet.images)) {
        $reference = [string]$image.reference
        $expectedId = if ($image.PSObject.Properties.Name -contains "imageId") { [string]$image.imageId } else { [string]$image.id }
        if ([string]::IsNullOrWhiteSpace($reference) -or $expectedId -notmatch '^sha256:[0-9a-f]{64}$') {
            throw "The release image set contains an invalid image record."
        }
        $actual = Get-RakazoImageRecord -DockerContext $DockerContext -Reference $reference
        if ([string]$actual.id -ne $expectedId) {
            throw "Loaded image does not match the release image-set manifest: $reference"
        }
    }
}

function Wait-RakazoMigrationPostgres {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DockerContext,
        [Parameter(Mandatory)][string[]]$ComposeArguments,
        [Parameter(Mandatory)][string]$DatabaseUser,
        [Parameter(Mandatory)][string]$DatabaseName,
        [ValidateRange(10, 300)][int]$TimeoutSeconds = 90
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $probe = Invoke-RakazoNativeCommand -FilePath "docker" -ArgumentList (@("--context", $DockerContext) + $ComposeArguments + @(
            "exec", "-T", "postgres", "pg_isready", "-U", $DatabaseUser, "-d", $DatabaseName
        )) -Quiet -AllowFailure
        if ($probe.ExitCode -eq 0) { return }
        Start-Sleep -Seconds 1
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Migration PostgreSQL did not become ready."
}

function Get-RakazoMigrationComputerRuntimeResetSql {
    return @'
BEGIN;
DELETE FROM computer_execution_leases;
UPDATE computers
SET state = 'stopped',
    "providerRef" = NULL,
    "screenUrl" = NULL,
    "controlHolder" = 'none',
    "controlLeaseId" = NULL,
    "controlLeaseExpiresAt" = NULL,
    "controlBotId" = NULL,
    "controlRunId" = NULL,
    "controlFence" = 0,
    "executionRunId" = NULL,
    "executionBotId" = NULL,
    "executionLeaseExpiresAt" = NULL,
    "executionFence" = 0;
UPDATE bots SET "computerSwitching" = FALSE WHERE "computerSwitching" = TRUE;
COMMIT;
'@
}

function Reset-RakazoMigrationComputerRuntime {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DockerContext,
        [Parameter(Mandatory)][string[]]$ComposeArguments,
        [Parameter(Mandatory)][string]$DatabaseUser,
        [Parameter(Mandatory)][string]$DatabaseName
    )

    # Provider references, screen URLs, and leases identify live processes owned by the source
    # deployment. Bot homes and their homeRevision are durable and deliberately remain untouched.
    Invoke-RakazoDocker -DockerContext $DockerContext -Arguments ($ComposeArguments + @(
        "exec", "-T", "postgres", "psql", "-v", "ON_ERROR_STOP=1",
        "-U", $DatabaseUser, "-d", $DatabaseName, "-c", (Get-RakazoMigrationComputerRuntimeResetSql)
    )) -Quiet | Out-Null
}

function Restore-RakazoMigrationState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DockerContext,
        [Parameter(Mandatory)][string[]]$ComposeArguments,
        [Parameter(Mandatory)][string]$RecoveryPointDirectory,
        [Parameter(Mandatory)][string]$AppDataVolume,
        [Parameter(Mandatory)][string]$DatabaseUser,
        [Parameter(Mandatory)][string]$DatabaseName
    )

    Invoke-RakazoDocker -DockerContext $DockerContext -Arguments ($ComposeArguments + @("run", "--rm", "data-init")) -Quiet | Out-Null
    Invoke-RakazoDocker -DockerContext $DockerContext -Arguments @(
        "run", "--rm",
        "--mount", "source=$AppDataVolume,target=/data",
        "--mount", "type=bind,source=$RecoveryPointDirectory,target=/backup,readonly",
        "busybox:1", "sh", "-c",
        "tar -xzf /backup/rakazo-appdata.tar.gz -C /data && chown -R 1000:1000 /data"
    ) -Quiet | Out-Null

    Invoke-RakazoDocker -DockerContext $DockerContext -Arguments ($ComposeArguments + @("up", "-d", "postgres")) -Quiet | Out-Null
    Wait-RakazoMigrationPostgres -DockerContext $DockerContext -ComposeArguments $ComposeArguments `
        -DatabaseUser $DatabaseUser -DatabaseName $DatabaseName
    $postgresId = Get-RakazoDockerOutput -DockerContext $DockerContext -Arguments ($ComposeArguments + @("ps", "-q", "postgres"))
    if ([string]::IsNullOrWhiteSpace($postgresId)) { throw "Migration PostgreSQL container was not found." }
    Invoke-RakazoDocker -DockerContext $DockerContext -Arguments @(
        "cp", (Join-Path $RecoveryPointDirectory "rakazo.pgdump"), "${postgresId}:/tmp/rakazo-migration.pgdump"
    ) -Quiet | Out-Null
    try {
        Invoke-RakazoDocker -DockerContext $DockerContext -Arguments ($ComposeArguments + @(
            "exec", "-T", "postgres", "pg_restore", "-U", $DatabaseUser, "-d", $DatabaseName,
            "--clean", "--if-exists", "--no-owner", "--no-privileges", "/tmp/rakazo-migration.pgdump"
        )) -Quiet | Out-Null
        Reset-RakazoMigrationComputerRuntime -DockerContext $DockerContext -ComposeArguments $ComposeArguments `
            -DatabaseUser $DatabaseUser -DatabaseName $DatabaseName
    }
    finally {
        Invoke-RakazoNativeCommand -FilePath "docker" -ArgumentList (@("--context", $DockerContext) + $ComposeArguments + @(
            "exec", "-T", "postgres", "rm", "-f", "/tmp/rakazo-migration.pgdump"
        )) -Quiet -AllowFailure | Out-Null
    }
}

function Get-RakazoMigrationFingerprint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DockerContext,
        [Parameter(Mandatory)][string[]]$ComposeArguments,
        [Parameter(Mandatory)][string]$AppDataVolume,
        [Parameter(Mandatory)][string]$DatabaseUser,
        [Parameter(Mandatory)][string]$DatabaseName
    )

    $queries = [ordered]@{
        users = 'SELECT count(*) FROM "user";'
        bots = 'SELECT count(*) FROM bots;'
        groups = 'SELECT count(*) FROM chat_groups;'
        threads = 'SELECT count(*) FROM threads;'
        messages = 'SELECT count(*) FROM messages;'
    }
    $counts = [ordered]@{}
    foreach ($entry in $queries.GetEnumerator()) {
        $value = Get-RakazoDockerOutput -DockerContext $DockerContext -Arguments ($ComposeArguments + @(
            "exec", "-T", "postgres", "psql", "-U", $DatabaseUser, "-d", $DatabaseName, "-At", "-c", $entry.Value
        ))
        if ($value -notmatch '^\d+$') { throw "Could not calculate the migration database fingerprint for $($entry.Key)." }
        $counts[$entry.Key] = [long]$value
    }
    $fileCount = Get-RakazoDockerOutput -DockerContext $DockerContext -Arguments @(
        "run", "--rm", "--mount", "source=$AppDataVolume,target=/data,readonly",
        "busybox:1", "sh", "-c", "find /data -type f | wc -l"
    )
    if ($fileCount -notmatch '^\s*\d+\s*$') { throw "Could not calculate the migration appdata fingerprint." }
    return [pscustomobject]@{ Database = [pscustomobject]$counts; AppDataFiles = [long]$fileCount.Trim() }
}

function Compare-RakazoMigrationFingerprint {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Expected, [Parameter(Mandatory)]$Actual)

    foreach ($name in @("users", "bots", "groups", "threads", "messages")) {
        if ([long]$Expected.Database.$name -ne [long]$Actual.Database.$name) {
            throw "Migration fingerprint changed for $name."
        }
    }
    if ([long]$Expected.AppDataFiles -ne [long]$Actual.AppDataFiles) {
        throw "Migration fingerprint changed for appdata files."
    }
}
