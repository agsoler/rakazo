[CmdletBinding()]
param([string]$DockerContext = "desktop-linux")

$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$temporaryWorktree = Join-Path ([IO.Path]::GetTempPath()) ("rakazo-supervisor-" + [guid]::NewGuid())
$patchPath = Join-Path $PSScriptRoot "windows-supervisor.patch"

try {
    git -C $repoRoot worktree add --detach $temporaryWorktree HEAD
    if ($LASTEXITCODE -ne 0) { throw "Could not create the temporary supervisor build worktree." }

    git -C $temporaryWorktree apply $patchPath
    if ($LASTEXITCODE -ne 0) { throw "Could not apply the Windows supervisor path patch." }

    docker --context $DockerContext build `
        -t rakazo-dev-supervisor:latest `
        -f (Join-Path $temporaryWorktree "infra\sandboxes\supervisor\Dockerfile") `
        $temporaryWorktree
    if ($LASTEXITCODE -ne 0) { throw "Could not build the Windows-compatible supervisor image." }
}
finally {
    git -C $repoRoot worktree remove --force $temporaryWorktree 2>$null
}
