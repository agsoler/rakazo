<#
.SYNOPSIS
Checks the host prerequisites for rakazo-personal operations.
.DESCRIPTION
Performs read-only version, Docker, Compose, Ollama, and optional Restic checks. Returns a non-zero
exit code when a required dependency is missing; use -AsJson for machine-readable output.
.EXAMPLE
.\scripts\windows-personal\Test-RakazoPersonalPrerequisites.ps1 -RequireRestic
#>
[CmdletBinding()]
param(
    [string]$DockerContext = "desktop-linux",
    [switch]$RequireRestic,
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "RakazoPersonal.Common.ps1")
$results = [Collections.Generic.List[object]]::new()

function Add-Result {
    param([string]$Component, [string]$Status, [string]$Observed, [string]$Required, [string]$Action)
    $results.Add([pscustomobject]@{ Component = $Component; Status = $Status; Observed = $Observed; Required = $Required; Action = $Action })
}

$pwshVersion = $PSVersionTable.PSVersion.ToString()
Add-Result "PowerShell" $(if ($PSVersionTable.PSVersion.Major -ge 7) { "PASS" } else { "FAIL" }) $pwshVersion "7 or newer" "Install with winget: Microsoft.PowerShell"

foreach ($command in @("git", "docker")) {
    $found = Get-Command $command -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    Add-Result $command $(if ($found) { "PASS" } else { "FAIL" }) $(if ($found) { $found.Source } else { "Not found" }) "Available on PATH" "Install the missing dependency"
}

if (Get-Command docker -ErrorAction SilentlyContinue) {
    $docker = Invoke-RakazoNativeCommand -FilePath "docker" -ArgumentList @("--context", $DockerContext, "info", "--format", "{{.ServerVersion}}") -Quiet -AllowFailure
    Add-Result "Docker engine" $(if ($docker.ExitCode -eq 0) { "PASS" } else { "FAIL" }) $(if ($docker.ExitCode -eq 0) { $docker.Output -join "" } else { "Unavailable" }) "Linux engine via $DockerContext" "Start Docker Desktop and select Linux containers"
    $compose = Invoke-RakazoNativeCommand -FilePath "docker" -ArgumentList @("compose", "version", "--short") -Quiet -AllowFailure
    Add-Result "Docker Compose" $(if ($compose.ExitCode -eq 0) { "PASS" } else { "FAIL" }) $(if ($compose.ExitCode -eq 0) { $compose.Output -join "" } else { "Unavailable" }) "Compose v2+" "Install/update Docker Desktop"
}

try {
    $ollama = Invoke-RestMethod -Uri "http://127.0.0.1:11434/api/tags" -TimeoutSec 5
    Add-Result "Ollama" "PASS" "$(@($ollama.models).Count) model entries reachable" "Host API on 127.0.0.1:11434" "None"
}
catch {
    Add-Result "Ollama" "FAIL" "Unavailable" "Host API on 127.0.0.1:11434" "Start Ollama"
}

$restic = Get-Command restic -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
$resticStatus = if ($restic) { "PASS" } elseif ($RequireRestic) { "FAIL" } else { "INFO" }
Add-Result "Restic" $resticStatus $(if ($restic) { (& $restic.Source version | Select-Object -First 1) } else { "Not installed" }) "Required only for encrypted NAS replication" "Install before configuring Sync"

$failed = @($results | Where-Object Status -eq "FAIL")
if ($AsJson) { $results | ConvertTo-Json -Depth 4 }
else { $results | Format-Table -AutoSize }
if ($failed.Count -gt 0) { exit 1 }
