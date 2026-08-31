[CmdletBinding()]
param(
    [string]$DestinationDirectory = [Environment]::GetFolderPath("Desktop"),
    [switch]$ConfirmShortcutInstallation
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not $ConfirmShortcutInstallation) {
    throw "This creates Windows shortcuts. Re-run with -ConfirmShortcutInstallation after reviewing DestinationDirectory."
}
if (-not $IsWindows) { throw "Windows shortcuts can be installed only on Windows." }
if (-not (Test-Path -LiteralPath $DestinationDirectory -PathType Container)) { throw "Shortcut destination does not exist: $DestinationDirectory" }

$pwsh = (Get-Process -Id $PID).Path
$actionScript = Join-Path $PSScriptRoot "Invoke-RakazoPersonalAction.ps1"
$shell = New-Object -ComObject WScript.Shell
$actions = @("Backup", "Update", "Restore", "Sync", "Start", "Stop", "Status")
foreach ($action in $actions) {
    $shortcutPath = Join-Path $DestinationDirectory "Rakazo Personal - $action.lnk"
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $pwsh
    $shortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$actionScript`" -Action $action"
    $shortcut.WorkingDirectory = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
    $shortcut.Description = "Rakazo personal stable: $Action"
    $shortcut.Save()
    Write-Host "Created: $shortcutPath"
}
