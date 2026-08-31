[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet("Backup", "Update", "Restore", "Sync", "Start", "Stop", "Status")]
    [string]$Action
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

try {
    switch ($Action) {
        "Backup" { & (Join-Path $PSScriptRoot "Backup-RakazoPersonal.ps1") }
        "Update" { & (Join-Path $PSScriptRoot "Update-RakazoPersonal.ps1") }
        "Sync" { & (Join-Path $PSScriptRoot "Sync-RakazoPersonalBackups.ps1") }
        "Start" { & (Join-Path $PSScriptRoot "Start-RakazoPersonal.ps1") }
        "Stop" { & (Join-Path $PSScriptRoot "Stop-RakazoPersonal.ps1") }
        "Status" { & (Join-Path $PSScriptRoot "Get-RakazoPersonalStatus.ps1") }
        "Restore" {
            . (Join-Path $PSScriptRoot "RakazoPersonal.Common.ps1")
            $context = Get-RakazoPersonalContext
            [void](Assert-RakazoPersonalInitialized $context)
            $points = @(Get-ChildItem -LiteralPath $context.RecoveryPointRoot -Directory | Where-Object Name -notlike ".*.incomplete" | Sort-Object Name -Descending)
            if (-not $points.Count) { throw "No local personal recovery points were found. Retrieve one from encrypted storage first if necessary." }
            Write-Host "Available personal recovery points:"
            for ($index = 0; $index -lt $points.Count; $index++) { Write-Host "  [$($index + 1)] $($points[$index].Name)" }
            $selection = Read-Host "Enter the recovery-point number, or press Enter to cancel"
            if ([string]::IsNullOrWhiteSpace($selection)) { Write-Host "Restore cancelled."; return }
            $number = 0
            if (-not [int]::TryParse($selection, [ref]$number) -or $number -lt 1 -or $number -gt $points.Count) { throw "Invalid recovery-point selection." }
            $point = $points[$number - 1].FullName
            & (Join-Path $PSScriptRoot "Test-RakazoPersonalRecoveryPoint.ps1") -RecoveryPointDirectory $point
            Write-Host "Restore replaces the personal database and bot files after making a safety backup." -ForegroundColor Yellow
            $confirmation = Read-Host "Type RESTORE rakazo-personal to continue"
            & (Join-Path $PSScriptRoot "Restore-RakazoPersonal.ps1") -RecoveryPointDirectory $point -ConfirmationPhrase $confirmation
        }
    }
    Write-Host "`n$Action finished."
}
catch {
    Write-Host "`n$Action failed: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
finally {
    if ($Host.Name -notmatch 'ServerRemoteHost') { [void](Read-Host "Press Enter to close") }
}
