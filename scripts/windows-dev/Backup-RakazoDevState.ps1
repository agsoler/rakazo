[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$DestinationDirectory,
    [switch]$ValidateOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$envFile = Join-Path $repoRoot ".env"
$dataDirectory = Join-Path $repoRoot ".local\data"
$composeFile = Join-Path $repoRoot "infra\compose\docker-compose.yml"
$composeOverride = Join-Path $PSScriptRoot "docker-compose.dev.yml"
$stopScript = Join-Path $PSScriptRoot "Stop-RakazoDev.ps1"
$startScript = Join-Path $PSScriptRoot "Start-RakazoDev.ps1"

if (-not [IO.Path]::IsPathRooted($DestinationDirectory)) {
    throw "DestinationDirectory must be an absolute path on encrypted external or remote storage."
}
if (-not (Test-Path -LiteralPath $DestinationDirectory -PathType Container)) {
    throw "DestinationDirectory does not exist. Create and verify the off-machine destination first."
}
if (-not (Test-Path -LiteralPath $envFile -PathType Leaf)) {
    throw ".env is missing. It is required to recover encrypted Rakazo state."
}
if (-not (Test-Path -LiteralPath $dataDirectory -PathType Container)) {
    throw ".local/data is missing. Start Rakazo development at least once before backing it up."
}

$resolvedDestination = (Resolve-Path -LiteralPath $DestinationDirectory).Path
$repositoryPrefix = $repoRoot.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
if ($resolvedDestination.Equals($repoRoot, [StringComparison]::OrdinalIgnoreCase) -or
    $resolvedDestination.StartsWith($repositoryPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "The backup destination must be outside the public Git repository."
}

$requiredCommands = @("docker", "git", "tar.exe")
$missingCommands = @($requiredCommands | Where-Object { -not (Get-Command $_ -ErrorAction SilentlyContinue) })
if ($missingCommands.Count -gt 0) {
    throw "Missing backup prerequisites: $($missingCommands -join ', ')."
}

$commit = (& git -C $repoRoot rev-parse HEAD).Trim()
$branch = (& git -C $repoRoot branch --show-current).Trim()
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$recoveryPointName = "rakazo-dev-state-$timestamp-$($commit.Substring(0, 8))"
$incompletePath = Join-Path $resolvedDestination ".$recoveryPointName.incomplete"
$finalPath = Join-Path $resolvedDestination $recoveryPointName
$composeArgs = @(
    "--context", "desktop-linux", "compose", "-p", "rakazo-dev",
    "--env-file", $envFile, "-f", $composeFile, "-f", $composeOverride
)

if ($ValidateOnly) {
    & (Join-Path $PSScriptRoot "Test-RakazoDevPrerequisites.ps1")
    if ($LASTEXITCODE -ne 0) {
        throw "Backup validation failed because one or more development prerequisites failed their audit."
    }
    Write-Host "Backup validation passed."
    Write-Host "Source commit: $commit ($branch)"
    Write-Host "Destination: $finalPath"
    Write-Host "A real run will briefly stop port 5300, snapshot PostgreSQL and .local/data, then restore the previous running state."
    exit 0
}

$toolchain = & (Join-Path $PSScriptRoot "Resolve-NodeToolchain.ps1") `
    -ShimDirectory (Join-Path $repoRoot ".local\run\toolchain")

if ((Test-Path -LiteralPath $incompletePath) -or (Test-Path -LiteralPath $finalPath)) {
    throw "The recovery-point path already exists: $recoveryPointName"
}

$wasRunning = $false
try {
    $response = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:5300" -TimeoutSec 3
    $wasRunning = $response.StatusCode -eq 200
}
catch {
    $wasRunning = $false
}

$postgresStarted = $false
$backupComplete = $false
New-Item -ItemType Directory -Path $incompletePath | Out-Null

try {
    & $stopScript

    & docker @composeArgs up -d postgres
    if ($LASTEXITCODE -ne 0) { throw "Could not start the isolated development database for backup." }
    $postgresStarted = $true

    $databaseReady = $false
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        & docker @composeArgs exec -T postgres pg_isready -U rakazo -d rakazo *> $null
        if ($LASTEXITCODE -eq 0) {
            $databaseReady = $true
            break
        }
        Start-Sleep -Seconds 1
    }
    if (-not $databaseReady) { throw "PostgreSQL did not become ready for backup." }

    & docker @composeArgs exec -T postgres pg_dump `
        -U rakazo -d rakazo --clean --if-exists --no-owner --no-privileges `
        --file=/tmp/rakazo-dev-state.sql
    if ($LASTEXITCODE -ne 0) { throw "PostgreSQL could not create the logical database dump." }
    & docker @composeArgs cp "postgres:/tmp/rakazo-dev-state.sql" (Join-Path $incompletePath "database.sql")
    if ($LASTEXITCODE -ne 0) { throw "The database dump could not be copied into the recovery point." }

    & tar.exe -czf (Join-Path $incompletePath "appdata.tar.gz") -C $dataDirectory .
    if ($LASTEXITCODE -ne 0) { throw "The bot-file archive could not be created." }
    Copy-Item -LiteralPath $envFile -Destination (Join-Path $incompletePath ".env")

    $dockerVersion = (& docker version --format '{{.Client.Version}}' 2>$null).Trim()
    $composeVersion = (& docker compose version --short 2>$null).Trim()
    $ollamaVersion = if (Get-Command ollama -ErrorAction SilentlyContinue) {
        (& ollama --version 2>$null | Select-Object -First 1).Trim()
    }
    else { "not recorded" }

    $manifest = [ordered]@{
        schemaVersion = 1
        createdAt = (Get-Date).ToUniversalTime().ToString("o")
        kind = "rakazo-dev-state"
        git = [ordered]@{ commit = $commit; branch = $branch }
        environment = [ordered]@{
            composeProject = "rakazo-dev"
            webPort = 5300
            apiPort = 3200
            postgresPort = 5433
            supervisorPort = 7091
        }
        tools = [ordered]@{
            powershell = $PSVersionTable.PSVersion.ToString()
            git = ((& git --version).Trim() -replace '^git version ', '')
            node = $toolchain.NodeVersion
            pnpm = ((& $toolchain.PnpmPath --version).Trim())
            docker = $dockerVersion
            compose = $composeVersion
            ollama = $ollamaVersion
        }
        files = @("database.sql", "appdata.tar.gz", ".env", "manifest.json", "checksums.sha256", "RECOVERY.txt")
    }
    $manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $incompletePath "manifest.json") -Encoding utf8

    @"
RAKAZO DEVELOPMENT STATE RECOVERY POINT

This directory contains private data and secrets. Keep it encrypted.

Git commit: $commit
Git branch at backup time: $branch

Contents:
- database.sql: users, bots, groups, conversations, settings, and other database records
- appdata.tar.gz: bot homes, files, revisions, and artifacts
- .env: matching encryption/authentication secrets and development configuration
- manifest.json: code revision and tool versions
- checksums.sha256: integrity hashes for the recovery files

Restore this recovery point only into the isolated rakazo-dev environment. Clone the recorded Git
commit first, verify the checksums, and follow docs/fork-development-handbook.md. Restoring the
database and appdata replaces current development state, so preserve the current state first.
"@ | Set-Content -LiteralPath (Join-Path $incompletePath "RECOVERY.txt") -Encoding utf8

    $hashFiles = @("database.sql", "appdata.tar.gz", ".env", "manifest.json", "RECOVERY.txt")
    $hashLines = foreach ($name in $hashFiles) {
        $hash = Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $incompletePath $name)
        "$($hash.Hash.ToLowerInvariant()) *$name"
    }
    $hashLines | Set-Content -LiteralPath (Join-Path $incompletePath "checksums.sha256") -Encoding ascii

    Move-Item -LiteralPath $incompletePath -Destination $finalPath
    $backupComplete = $true
}
finally {
    if ($postgresStarted) {
        & docker @composeArgs exec -T postgres rm -f /tmp/rakazo-dev-state.sql *> $null
    }
    if ($wasRunning) {
        & $startScript
    }
    elseif ($postgresStarted) {
        & docker @composeArgs stop postgres *> $null
    }
}

if ($backupComplete) {
    Write-Host "Development state recovery point created: $finalPath"
    Write-Host "It contains secrets. Keep it encrypted and verify that it is physically off this computer."
}
