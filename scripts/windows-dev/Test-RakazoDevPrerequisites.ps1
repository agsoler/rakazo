[CmdletBinding()]
param([switch]$AsJson)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$results = [Collections.Generic.List[object]]::new()

function Add-Result {
    param(
        [string]$Component,
        [ValidateSet("PASS", "FAIL", "INFO")][string]$Status,
        [string]$Observed,
        [string]$Required,
        [string]$Action
    )

    $results.Add([pscustomobject]@{
        Component = $Component
        Status = $Status
        Observed = $Observed
        Required = $Required
        Action = $Action
    })
}

$powerShellVersion = $PSVersionTable.PSVersion
Add-Result `
    -Component "PowerShell" `
    -Status $(if ($powerShellVersion.Major -ge 7) { "PASS" } else { "FAIL" }) `
    -Observed $powerShellVersion.ToString() `
    -Required "PowerShell 7 or newer" `
    -Action "Install: winget install --id Microsoft.PowerShell --source winget"

$git = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if ($git) {
    $gitVersion = (& $git.Source --version).Trim() -replace '^git version ', ''
    Add-Result -Component "Git" -Status "PASS" -Observed $gitVersion -Required "Current supported Git for Windows" -Action "None"
}
else {
    Add-Result -Component "Git" -Status "FAIL" -Observed "Not found" -Required "Current supported Git for Windows" -Action "Install: winget install --id Git.Git -e --source winget"
}

$node = Get-Command node -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $node) {
    Add-Result -Component "Node.js" -Status "FAIL" -Observed "Not found" -Required "22.22.2+, 24.15.0+, or 26+; not 23 or 25" -Action "Install a compatible Node LTS release from https://nodejs.org/en/download"
}
else {
    $nodeVersionText = (& $node.Source -p "process.versions.node").Trim()
    $nodeVersion = [version]$nodeVersionText
    $nodeSupported =
        ($nodeVersion.Major -eq 22 -and $nodeVersion -ge [version]"22.22.2") -or
        ($nodeVersion.Major -eq 24 -and $nodeVersion -ge [version]"24.15.0") -or
        ($nodeVersion.Major -ge 26)
    Add-Result `
        -Component "Node.js" `
        -Status $(if ($nodeSupported) { "PASS" } else { "FAIL" }) `
        -Observed $nodeVersionText `
        -Required "22.22.2+, 24.15.0+, or 26+; not 23 or 25" `
        -Action $(if ($nodeSupported) { "None" } else { "Install a compatible Node LTS release from https://nodejs.org/en/download" })

    $nodeDirectory = Split-Path -Parent (& $node.Source -p "process.execPath").Trim()
    $adjacentCorepack = Join-Path $nodeDirectory "corepack.cmd"
    $corepack = if (Test-Path -LiteralPath $adjacentCorepack) {
        $adjacentCorepack
    }
    else {
        $corepackCommand = Get-Command corepack -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($corepackCommand) { $corepackCommand.Source } else { $null }
    }
    $packageManager = (Get-Content -Raw -LiteralPath (Join-Path $repoRoot "package.json") | ConvertFrom-Json).packageManager
    $pnpmPinned = $packageManager -eq "pnpm@9.15.0"
    Add-Result `
        -Component "pnpm" `
        -Status $(if ($corepack -and $pnpmPinned) { "PASS" } else { "FAIL" }) `
        -Observed $(if (-not $corepack) { "Corepack not found" } else { $packageManager }) `
        -Required "Repository-pinned pnpm 9.15.0 through Corepack" `
        -Action $(if ($corepack -and $pnpmPinned) { "Prepared automatically by the Rakazo start and backup scripts" } else { "Install compatible Node with Corepack support" })
}

$docker = Get-Command docker -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $docker) {
    Add-Result -Component "Docker Desktop" -Status "FAIL" -Observed "docker command not found" -Required "Current Docker Desktop using Linux containers and Compose v2" -Action "Install: winget install --id Docker.DockerDesktop -e --source winget"
}
else {
    $dockerVersion = ((@(& $docker.Source version --format '{{.Client.Version}}' 2>$null) -join "").Trim())
    if (-not $dockerVersion) { $dockerVersion = "version unavailable" }
    $composeVersion = ((@(& $docker.Source compose version --short 2>$null) -join "").Trim())
    if (-not $composeVersion) { $composeVersion = "version unavailable" }
    $dockerOs = ((@(& $docker.Source --context desktop-linux info --format '{{.OSType}}' 2>$null) -join "").Trim())
    $dockerEngineExitCode = $LASTEXITCODE
    if ($dockerEngineExitCode -eq 0 -and $dockerOs -eq "linux") {
        Add-Result -Component "Docker Desktop" -Status "PASS" -Observed "Docker $dockerVersion; Compose $composeVersion; Linux engine reachable" -Required "Current Docker Desktop using Linux containers and Compose v2" -Action "None"
    }
    else {
        Add-Result -Component "Docker Desktop" -Status "FAIL" -Observed "Docker $dockerVersion is installed, but the desktop-linux engine is unavailable" -Required "Docker Desktop running with Linux containers" -Action "Start Docker Desktop and select Linux containers"
    }
}

$ollama = Get-Command ollama -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $ollama) {
    Add-Result -Component "Ollama" -Status "FAIL" -Observed "ollama command not found" -Required "Current Ollama for Windows; API on 127.0.0.1:11434" -Action "Install: winget install --id Ollama.Ollama -e --source winget"
}
else {
    $ollamaVersion = (& $ollama.Source --version 2>$null | Select-Object -First 1).Trim()
    try {
        $ollamaTags = Invoke-RestMethod -Uri "http://127.0.0.1:11434/api/tags" -TimeoutSec 5
        $availableModels = @($ollamaTags.models | ForEach-Object name)
        Add-Result -Component "Ollama" -Status "PASS" -Observed "$ollamaVersion; API reachable; $($availableModels.Count) model entries" -Required "Current Ollama for Windows; API on 127.0.0.1:11434" -Action "None"

        $envPath = Join-Path $repoRoot ".env"
        $modelLine = if (Test-Path -LiteralPath $envPath) {
            Get-Content -LiteralPath $envPath | Where-Object { $_ -match '^RAKAZO_LOCAL_MODELS=' } | Select-Object -First 1
        }
        else { $null }
        $requiredModels = if ($modelLine) {
            @($modelLine.Substring("RAKAZO_LOCAL_MODELS=".Length).Split(",", [StringSplitOptions]::RemoveEmptyEntries) | ForEach-Object Trim)
        }
        else {
            @("deepseek-v4-flash:cloud", "qwen3.6:27b")
        }
        $missingModels = @($requiredModels | Where-Object { $_ -notin $availableModels })
        if ($missingModels.Count -eq 0) {
            Add-Result -Component "Ollama models" -Status "PASS" -Observed ($requiredModels -join ", ") -Required "Every model named by RAKAZO_LOCAL_MODELS" -Action "None"
        }
        else {
            Add-Result -Component "Ollama models" -Status "FAIL" -Observed ("Missing: " + ($missingModels -join ", ")) -Required "Every model named by RAKAZO_LOCAL_MODELS" -Action ("Run ollama pull for each missing local model; cloud models require Ollama sign-in")
        }
    }
    catch {
        Add-Result -Component "Ollama" -Status "FAIL" -Observed "$ollamaVersion is installed, but its API is unreachable" -Required "Ollama running on 127.0.0.1:11434" -Action "Start Ollama from the Windows Start menu"
    }
}

$winget = Get-Command winget -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
Add-Result `
    -Component "WinGet (optional)" `
    -Status $(if ($winget) { "INFO" } else { "INFO" }) `
    -Observed $(if ($winget) { (& $winget.Source --version).Trim() } else { "Not found" }) `
    -Required "Optional installer helper; manual installers also work" `
    -Action $(if ($winget) { "Available" } else { "Use the official installer links in the handbook" })

if ($AsJson) {
    $results | ConvertTo-Json -Depth 4
}
else {
    $results | Format-Table -Wrap -AutoSize Component, Status, Observed, Required, Action
    Write-Host ""
    Write-Host "Official installers and exact version rules: docs/fork-development-handbook.md"
}

if ($results.Status -contains "FAIL") { exit 1 }
