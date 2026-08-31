[CmdletBinding()]
param(
    [string[]]$Models = @("deepseek-v4-flash:cloud", "qwen3.6:27b"),
    [string]$DefaultModel = "deepseek-v4-flash:cloud"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$templatePath = Join-Path $repoRoot ".env.example"
$envPath = Join-Path $repoRoot ".env"

if (Test-Path -LiteralPath $envPath) {
    throw ".env already exists. This initializer never overwrites an existing configuration."
}
if (-not (Test-Path -LiteralPath $templatePath)) {
    throw "Environment template not found: $templatePath"
}
if ($Models.Count -eq 0) {
    throw "At least one Ollama model must be supplied."
}
if ($DefaultModel -notin $Models) {
    throw "DefaultModel must also appear in Models."
}

function New-HexSecret {
    param([int]$Bytes)

    $buffer = [byte[]]::new($Bytes)
    [Security.Cryptography.RandomNumberGenerator]::Fill($buffer)
    return [Convert]::ToHexString($buffer).ToLowerInvariant()
}

$values = [ordered]@{
    NODE_ENV                    = "development"
    DATABASE_URL                = "postgres://rakazo:rakazo@127.0.0.1:5433/rakazo"
    BETTER_AUTH_SECRET          = New-HexSecret 32
    BETTER_AUTH_URL             = "http://127.0.0.1:5300"
    API_URL                     = "http://127.0.0.1:3200"
    API_HOST                    = "127.0.0.1"
    API_PORT                    = "3200"
    API_PROXY_TARGET            = "http://127.0.0.1:3200"
    WEB_ORIGIN                  = "http://127.0.0.1:5300"
    WEB_PORT                    = "5300"
    ENCRYPTION_KEY              = New-HexSecret 32
    DATA_DIR                    = "./.local/data"
    SANDBOX_SUPERVISOR_URL      = "http://127.0.0.1:7091"
    SANDBOX_SUPERVISOR_TOKEN    = New-HexSecret 32
    SCREEN_PROXY_SECRET         = New-HexSecret 32
    SANDBOX_PROVIDER            = "docker"
    AGENT_RUNTIME               = "pi"
    WAKEUP_DRIVER               = "graphile"
    RAKAZO_LOCAL_MODELS         = $Models -join ","
    RAKAZO_LOCAL_MODELS_URL     = "http://127.0.0.1:11434/v1"
    RAKAZO_LOCAL_CONTEXT_WINDOW = "32768"
    RAKAZO_LOCAL_MAX_TOKENS     = "4096"
    PI_DEFAULT_PROVIDER         = "local"
    PI_DEFAULT_MODEL            = $DefaultModel
    LOG_LEVEL                   = "info"
}

$seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$output = foreach ($line in Get-Content -LiteralPath $templatePath) {
    if ($line -match '^(?<name>[A-Z][A-Z0-9_]*)=') {
        $name = $Matches.name
        if ($values.Contains($name)) {
            [void]$seen.Add($name)
            "${name}=$($values[$name])"
            continue
        }
    }
    $line
}

$missing = foreach ($entry in $values.GetEnumerator()) {
    if (-not $seen.Contains($entry.Key)) {
        "$($entry.Key)=$($entry.Value)"
    }
}
if (@($missing).Count -gt 0) {
    $output += ""
    $output += "# --- Isolated Windows development overrides ---"
    $output += $missing
}

$output | Set-Content -LiteralPath $envPath -Encoding utf8

Write-Host "Created a secret-bearing .env for the isolated Rakazo development environment."
Write-Host "Web: http://127.0.0.1:5300"
Write-Host "API: http://127.0.0.1:3200"
Write-Host "The file is ignored by Git. Back it up only to encrypted private storage."
