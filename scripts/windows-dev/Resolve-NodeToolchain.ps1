param([string]$ShimDirectory)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$nodeCommand = Get-Command node -CommandType Application -ErrorAction Stop | Select-Object -First 1
$nodeVersionText = (& $nodeCommand.Source -p "process.versions.node").Trim()
$nodeExecutable = (& $nodeCommand.Source -p "process.execPath").Trim()
$nodeVersion = [version]$nodeVersionText

$supported =
    ($nodeVersion.Major -eq 22 -and $nodeVersion -ge [version]"22.22.2") -or
    ($nodeVersion.Major -eq 24 -and $nodeVersion -ge [version]"24.15.0") -or
    ($nodeVersion.Major -ge 26)
if (-not $supported) {
    throw "Node $nodeVersionText is unsupported by the current Rakazo lockfile. Install Node 22.22.2+, 24.15.0+, or 26+ (do not use Node 23 or 25)."
}

$nodeDirectory = Split-Path -Parent $nodeExecutable
$adjacentCorepack = Join-Path $nodeDirectory "corepack.cmd"
if (Test-Path -LiteralPath $adjacentCorepack) {
    $corepackCommand = $adjacentCorepack
}
else {
    $corepackCommand = (Get-Command corepack -CommandType Application -ErrorAction Stop |
        Select-Object -First 1).Source
}

$pnpmCommand = $null
if ($ShimDirectory) {
    New-Item -ItemType Directory -Force $ShimDirectory | Out-Null
    & $corepackCommand enable --install-directory $ShimDirectory
    if ($LASTEXITCODE -ne 0) {
        throw "Corepack could not create the repository-local package-manager shims."
    }
    $env:PATH = "$ShimDirectory;$env:PATH"
    $pnpmCommand = (Get-Command pnpm -CommandType ExternalScript, Application -ErrorAction Stop |
        Select-Object -First 1).Source
    $pnpmVersion = (& $pnpmCommand --version).Trim()
    if ($pnpmVersion -ne "9.15.0") {
        throw "Expected repository-pinned pnpm 9.15.0 but resolved pnpm $pnpmVersion."
    }
}

[pscustomobject]@{
    NodeVersion = $nodeVersionText
    NodePath = $nodeExecutable
    CorepackPath = $corepackCommand
    PnpmPath = $pnpmCommand
}
