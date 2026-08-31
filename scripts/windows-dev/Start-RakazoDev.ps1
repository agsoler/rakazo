[CmdletBinding()]
param([string]$DockerContext = "desktop-linux")

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$envFile = Join-Path $repoRoot ".env"
$composeFile = Join-Path $repoRoot "infra\compose\docker-compose.yml"
$composeOverride = Join-Path $PSScriptRoot "docker-compose.dev.yml"
$stateDirectory = Join-Path $repoRoot ".local"
$localData = Join-Path $stateDirectory "data"
$runDirectory = Join-Path $stateDirectory "run"
$pidFile = Join-Path $runDirectory "source.pid"
$stdoutLog = Join-Path $runDirectory "source.out.log"
$stderrLog = Join-Path $runDirectory "source.err.log"
$runnerPath = Join-Path $PSScriptRoot "Run-RakazoDev.ps1"

Set-Location $repoRoot

if (-not (Test-Path -LiteralPath $envFile)) {
    throw ".env is missing. Run .\scripts\windows-dev\Initialize-RakazoDev.ps1 first."
}
$toolchain = & (Join-Path $PSScriptRoot "Resolve-NodeToolchain.ps1") `
    -ShimDirectory (Join-Path $runDirectory "toolchain")
Write-Host "Using Node $($toolchain.NodeVersion) from $($toolchain.NodePath)"

function Read-EnvValue {
    param([string]$Name, [string]$Default)

    $line = Get-Content -LiteralPath $envFile |
        Where-Object { $_ -match "^$([regex]::Escape($Name))=" } |
        Select-Object -First 1
    if (-not $line) { return $Default }
    return $line.Substring($Name.Length + 1).Trim()
}

$webPort = Read-EnvValue "WEB_PORT" "5300"
$apiPort = Read-EnvValue "API_PORT" "3200"
$env:WEB_PORT = $webPort
$env:SANDBOX_CLIENT_DATA_DIR = $localData
$webUrl = "http://127.0.0.1:$webPort/"
$apiHealthUrl = "http://127.0.0.1:$apiPort/health"
$composeArgs = @(
    "--context", $DockerContext, "compose", "-p", "rakazo-dev",
    "--env-file", $envFile, "-f", $composeFile, "-f", $composeOverride
)

New-Item -ItemType Directory -Force $runDirectory, $localData | Out-Null

if (Test-Path -LiteralPath $pidFile) {
    $existingPid = [int](Get-Content -Raw -LiteralPath $pidFile).Trim()
    $existingProcess = Get-CimInstance Win32_Process -Filter "ProcessId = $existingPid" -ErrorAction SilentlyContinue
    if ($existingProcess -and $existingProcess.CommandLine -like "*Run-RakazoDev.ps1*") {
        try {
            $existingWebResponse = Invoke-WebRequest -UseBasicParsing -Uri $webUrl -TimeoutSec 3
            $existingApiResponse = Invoke-WebRequest -UseBasicParsing -Uri $apiHealthUrl -TimeoutSec 3
            if ($existingWebResponse.StatusCode -eq 200 -and $existingApiResponse.StatusCode -eq 200) {
                Write-Host "Rakazo development is already running (PID $existingPid)."
                Write-Host "Open $webUrl"
                exit 0
            }
        }
        catch {
            # The tracked process exists but is unhealthy. Replace only that development process tree.
        }
        taskkill /PID $existingPid /T /F | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Could not replace the unhealthy Rakazo development process tree."
        }
    }
    Remove-Item -LiteralPath $pidFile -Force
}

docker --context $DockerContext info *> $null
if ($LASTEXITCODE -ne 0) {
    throw "Docker Desktop is not running or the '$DockerContext' context is unavailable."
}

try {
    Invoke-RestMethod -Uri "http://127.0.0.1:11434/api/tags" -TimeoutSec 5 | Out-Null
}
catch {
    throw "Ollama is not reachable at http://127.0.0.1:11434."
}

& docker @composeArgs up -d postgres
if ($LASTEXITCODE -ne 0) {
    throw "The isolated rakazo-dev PostgreSQL service failed to start."
}

& docker @composeArgs run --rm data-init
if ($LASTEXITCODE -ne 0) {
    throw "The isolated development data directory could not be prepared for sandbox UID 1000."
}

& (Join-Path $PSScriptRoot "Build-WindowsSupervisor.ps1") -DockerContext $DockerContext

& docker @composeArgs up -d supervisor
if ($LASTEXITCODE -ne 0) {
    throw "The isolated sandbox supervisor failed to start."
}

& $toolchain.PnpmPath install --frozen-lockfile
if ($LASTEXITCODE -ne 0) { throw "Rakazo dependencies could not be installed." }

& $toolchain.PnpmPath --filter @rakazo/db generate
if ($LASTEXITCODE -ne 0) { throw "The Prisma client could not be generated." }
& $toolchain.PnpmPath --filter @rakazo/db migrate
if ($LASTEXITCODE -ne 0) { throw "The development database migration failed." }
& $toolchain.PnpmPath sandbox:build
if ($LASTEXITCODE -ne 0) { throw "The development computer image could not be built." }

Write-Host "Rakazo development will be available at $webUrl"
Remove-Item -LiteralPath $stdoutLog, $stderrLog -Force -ErrorAction SilentlyContinue

$powershellPath = (Get-Process -Id $PID).Path
$sourceProcess = Start-Process `
    -FilePath $powershellPath `
    -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $runnerPath) `
    -WorkingDirectory $repoRoot `
    -WindowStyle Hidden `
    -RedirectStandardOutput $stdoutLog `
    -RedirectStandardError $stderrLog `
    -PassThru

$sourceProcess.Id | Set-Content -NoNewline -LiteralPath $pidFile

$ready = $false
for ($attempt = 0; $attempt -lt 45; $attempt++) {
    Start-Sleep -Seconds 1
    if ($sourceProcess.HasExited) { break }
    try {
        $webResponse = Invoke-WebRequest -UseBasicParsing -Uri $webUrl -TimeoutSec 2
        $apiResponse = Invoke-WebRequest -UseBasicParsing -Uri $apiHealthUrl -TimeoutSec 2
        if ($webResponse.StatusCode -eq 200 -and $apiResponse.StatusCode -eq 200) {
            $ready = $true
            break
        }
    }
    catch {
        # Source services are still starting.
    }
}

if (-not $ready) {
    if (-not $sourceProcess.HasExited) {
        taskkill /PID $sourceProcess.Id /T /F | Out-Null
    }
    Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
    $outputTail = if (Test-Path $stdoutLog) { Get-Content $stdoutLog -Tail 60 } else { @() }
    $errorTail = if (Test-Path $stderrLog) { Get-Content $stderrLog -Tail 60 } else { @() }
    throw "Rakazo web and API services did not become ready. See $stdoutLog and $stderrLog.`n$($outputTail -join "`n")`n$($errorTail -join "`n")"
}

Write-Host "Rakazo development is running in the background (PID $($sourceProcess.Id))."
Write-Host "Open $webUrl"
Write-Host "Logs: $stdoutLog and $stderrLog"
Write-Host "Stop it with .\scripts\windows-dev\Stop-RakazoDev.ps1"
