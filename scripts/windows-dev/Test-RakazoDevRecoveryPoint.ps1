[CmdletBinding()]
param([Parameter(Mandatory)][string]$RecoveryPointDirectory)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$recoveryPoint = (Resolve-Path -LiteralPath $RecoveryPointDirectory).Path
$requiredFiles = @("database.sql", "appdata.tar.gz", ".env", "manifest.json", "checksums.sha256", "RECOVERY.txt")
$missingFiles = @($requiredFiles | Where-Object { -not (Test-Path -LiteralPath (Join-Path $recoveryPoint $_) -PathType Leaf) })
if ($missingFiles.Count -gt 0) {
    throw "This is not a complete Rakazo development recovery point. Missing: $($missingFiles -join ', ')."
}

$manifest = Get-Content -Raw -LiteralPath (Join-Path $recoveryPoint "manifest.json") | ConvertFrom-Json
if ($manifest.schemaVersion -ne 1 -or $manifest.kind -ne "rakazo-dev-state") {
    throw "Unsupported recovery-point manifest."
}

$checksumFailures = [Collections.Generic.List[string]]::new()
foreach ($line in Get-Content -LiteralPath (Join-Path $recoveryPoint "checksums.sha256")) {
    if ($line -notmatch '^(?<hash>[0-9a-fA-F]{64}) \*(?<name>.+)$') {
        $checksumFailures.Add("Malformed checksum line: $line")
        continue
    }
    $filePath = Join-Path $recoveryPoint $Matches.name
    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        $checksumFailures.Add("Missing checksum target: $($Matches.name)")
        continue
    }
    $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $filePath).Hash
    if ($actual -ne $Matches.hash) {
        $checksumFailures.Add("Checksum mismatch: $($Matches.name)")
    }
}

if ($checksumFailures.Count -gt 0) {
    $checksumFailures | ForEach-Object { Write-Error $_ }
    throw "Recovery-point integrity verification failed. Do not restore it."
}

Write-Host "Recovery point is complete and every checksum matches."
Write-Host "Created (UTC): $($manifest.createdAt)"
Write-Host "Git commit: $($manifest.git.commit)"
Write-Host "Git branch at backup time: $($manifest.git.branch)"
Write-Host "Restore target: Docker project $($manifest.environment.composeProject), web port $($manifest.environment.webPort)"
Write-Host "This verification does not modify Rakazo or reveal the backed-up secrets."
