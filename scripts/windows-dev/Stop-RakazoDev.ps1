[CmdletBinding()]
param([string]$DockerContext = "desktop-linux")

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$envFile = Join-Path $repoRoot ".env"
$composeFile = Join-Path $repoRoot "infra\compose\docker-compose.yml"
$composeOverride = Join-Path $PSScriptRoot "docker-compose.dev.yml"
$pidFile = Join-Path $repoRoot ".local\run\source.pid"

Set-Location $repoRoot

if (Test-Path -LiteralPath $pidFile) {
    $sourcePid = [int](Get-Content -Raw -LiteralPath $pidFile).Trim()
    $sourceProcess = Get-CimInstance Win32_Process -Filter "ProcessId = $sourcePid" -ErrorAction SilentlyContinue
    if ($sourceProcess) {
        if ($sourceProcess.CommandLine -notlike "*Run-RakazoDev.ps1*") {
            throw "PID $sourcePid no longer belongs to a Rakazo development runner. Refusing to stop it."
        }
        taskkill /PID $sourcePid /T /F | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Could not stop the Rakazo development source-process tree."
        }
    }
    Remove-Item -LiteralPath $pidFile -Force
}

$composeArgs = @(
    "--context", $DockerContext, "compose", "-p", "rakazo-dev",
    "--env-file", $envFile, "-f", $composeFile, "-f", $composeOverride
)
& docker @composeArgs stop supervisor postgres
if ($LASTEXITCODE -ne 0) {
    throw "Could not stop the isolated rakazo-dev supervisor and PostgreSQL services."
}

Write-Host "rakazo-dev source processes, supervisor, and PostgreSQL stopped. Development data was preserved."
