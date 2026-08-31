$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
Set-Location $repoRoot
$toolchain = & (Join-Path $PSScriptRoot "Resolve-NodeToolchain.ps1") `
    -ShimDirectory (Join-Path $repoRoot ".local\run\toolchain")

$webPortLine = Get-Content .env | Where-Object { $_ -match '^WEB_PORT=' } | Select-Object -First 1
if (-not $webPortLine) {
    throw "WEB_PORT is missing from .env."
}
$env:WEB_PORT = $webPortLine.Substring("WEB_PORT=".Length).Trim()
$env:SANDBOX_CLIENT_DATA_DIR = Join-Path $repoRoot ".local\data"

& $toolchain.PnpmPath exec turbo dev --filter=@rakazo/api --filter=@rakazo/worker --filter=@rakazo/web --env-mode=loose
exit $LASTEXITCODE
