[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$modulePath = Join-Path $PSScriptRoot "..\Rakazo.Operations.psm1"
Import-Module $modulePath -Force

$script:Passed = 0
$script:Failed = 0

function Invoke-Test {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][scriptblock]$Body)

    try {
        & $Body
        $script:Passed++
        Write-Host "PASS $Name"
    }
    catch {
        $script:Failed++
        Write-Host "FAIL $Name`n  $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Assert-True {
    param([Parameter(Mandatory)][bool]$Condition, [string]$Message = "Expected true")
    if (-not $Condition) { throw $Message }
}

function Assert-False {
    param([Parameter(Mandatory)][bool]$Condition, [string]$Message = "Expected false")
    if ($Condition) { throw $Message }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Message = "Values differ")
    if ($Expected -ne $Actual) { throw "$Message. Expected '$Expected', got '$Actual'." }
}

function Assert-Throws {
    param([Parameter(Mandatory)][scriptblock]$Body, [string]$Message = "Expected an exception")
    try { & $Body } catch { return }
    throw $Message
}

function New-BotFixture {
    param(
        [bool]$Managed,
        [string]$Project,
        [string]$Source,
        [string]$Destination = "/home/rakazo"
    )
    $labels = [pscustomobject]@{
        'rakazo.managed' = $(if ($Managed) { "true" } else { "false" })
        'com.docker.compose.project' = $Project
    }
    return [pscustomobject]@{
        Config = [pscustomobject]@{ Labels = $labels }
        Mounts = @([pscustomobject]@{ Source = $Source; Destination = $Destination })
    }
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) "rakazo-operations-tests-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $testRoot | Out-Null

try {
    Invoke-Test "path containment accepts descendants but not the root or siblings" {
        $root = Join-Path $testRoot "root"
        Assert-True (Test-RakazoPathWithin -Path (Join-Path $root "child\file") -Root $root)
        Assert-False (Test-RakazoPathWithin -Path $root -Root $root)
        Assert-False (Test-RakazoPathWithin -Path (Join-Path $testRoot "root-other") -Root $root)
        Assert-Throws { Assert-RakazoSafeChildPath -Path (Join-Path $root "..\escape") -AllowedRoot $root }
    }

    Invoke-Test "environment files round-trip fake values without emitting them" {
        $path = Join-Path $testRoot "test.env"
        $values = [ordered]@{ SAFE_NAME = "value"; FAKE_SECRET = "not-a-real-secret" }
        $output = @(& { Write-RakazoEnvFile -Values $values -Path $path } 6>&1)
        $parsed = Read-RakazoEnvFile $path
        Assert-Equal "value" $parsed.SAFE_NAME
        Assert-Equal "not-a-real-secret" $parsed.FAKE_SECRET
        Assert-False (($output | Out-String).Contains("not-a-real-secret")) "Secret value was written to output"
    }

    Invoke-Test "checksums pass intact files and reject tampering" {
        $directory = Join-Path $testRoot "checksums"
        New-Item -ItemType Directory -Path $directory | Out-Null
        "alpha" | Set-Content -LiteralPath (Join-Path $directory "a.txt")
        Write-RakazoChecksums -Directory $directory -RelativePaths @("a.txt")
        $verified = @(Test-RakazoChecksums -Directory $directory)
        Assert-Equal 1 $verified.Count
        "tampered" | Set-Content -LiteralPath (Join-Path $directory "a.txt")
        Assert-Throws { Test-RakazoChecksums -Directory $directory }
    }

    Invoke-Test "image-set IDs are stable and change with an image ID" {
        $images = @(
            [ordered]@{ reference = "example/app:sha-a"; id = "sha256:1"; repoDigests = @(); architecture = "amd64"; os = "linux" },
            [ordered]@{ reference = "example/computer:sha-a"; id = "sha256:2"; repoDigests = @(); architecture = "amd64"; os = "linux" }
        )
        $first = New-RakazoImageSetManifest -Images $images -SourceCommit ("a" * 40)
        $second = New-RakazoImageSetManifest -Images @($images[1], $images[0]) -SourceCommit ("a" * 40)
        Assert-Equal $first.imageSetId $second.imageSetId
        $changed = @($images[0], [ordered]@{ reference = "example/computer:sha-a"; id = "sha256:3"; repoDigests = @(); architecture = "amd64"; os = "linux" })
        $third = New-RakazoImageSetManifest -Images $changed -SourceCommit ("a" * 40)
        Assert-False ($first.imageSetId -eq $third.imageSetId) "Image-set ID did not change"
    }

    Invoke-Test "bot ownership accepts only managed homes beneath the requested appdata root" {
        $root = "/var/lib/docker/volumes/rakazo-personal_appdata/_data"
        $owned = New-BotFixture -Managed $true -Project "" -Source "$root/homes/team-one"
        Assert-True (Test-RakazoBotOwnership -Container $owned -ExpectedAppDataRoot $root -ExpectedProject "rakazo-personal")
        $ownedWithProject = New-BotFixture -Managed $true -Project "rakazo-personal" -Source "$root/homes/team-two"
        Assert-True (Test-RakazoBotOwnership -Container $ownedWithProject -ExpectedAppDataRoot $root -ExpectedProject "rakazo-personal")
        $wrongProject = New-BotFixture -Managed $true -Project "rakazo-dev" -Source "$root/homes/team-three"
        Assert-False (Test-RakazoBotOwnership -Container $wrongProject -ExpectedAppDataRoot $root -ExpectedProject "rakazo-personal")
        $wrongRoot = New-BotFixture -Managed $true -Project "" -Source "/var/lib/docker/volumes/rakazo_appdata/_data/homes/team-four"
        Assert-False (Test-RakazoBotOwnership -Container $wrongRoot -ExpectedAppDataRoot $root -ExpectedProject "rakazo-personal")
        $unmanaged = New-BotFixture -Managed $false -Project "" -Source "$root/homes/team-five"
        Assert-False (Test-RakazoBotOwnership -Container $unmanaged -ExpectedAppDataRoot $root -ExpectedProject "rakazo-personal")
        $wrongDestination = New-BotFixture -Managed $true -Project "" -Source "$root/homes/team-six" -Destination "/workspace"
        Assert-False (Test-RakazoBotOwnership -Container $wrongDestination -ExpectedAppDataRoot $root -ExpectedProject "rakazo-personal")
    }

    Invoke-Test "atomic recovery points publish only after explicit completion" {
        $root = Join-Path $testRoot "atomic"
        $paths = New-RakazoAtomicDirectory -Root $root -Name "point-001"
        Assert-True (Test-Path -LiteralPath $paths.Incomplete)
        Assert-False (Test-Path -LiteralPath $paths.Final)
        "complete" | Set-Content -LiteralPath (Join-Path $paths.Incomplete "marker.txt")
        Complete-RakazoAtomicDirectory -IncompletePath $paths.Incomplete -FinalPath $paths.Final -AllowedRoot $root
        Assert-False (Test-Path -LiteralPath $paths.Incomplete)
        Assert-True (Test-Path -LiteralPath (Join-Path $paths.Final "marker.txt"))
    }

    Invoke-Test "personal recovery verification links state to an exact external image archive" {
        $fixtureRoot = Join-Path $testRoot "personal-recovery"
        $point = Join-Path $fixtureRoot "recovery-points\point-one"
        $imageDirectory = Join-Path $fixtureRoot "image-sets\sha256-fixture"
        New-Item -ItemType Directory -Force -Path $point, $imageDirectory | Out-Null
        "fake image archive" | Set-Content -LiteralPath (Join-Path $imageDirectory "rakazo-images.tar")
        $imageSet = [ordered]@{ schemaVersion = 1; kind = "rakazo-image-set"; imageSetId = "sha256-fixture"; source = [ordered]@{ commit = "fixture" }; images = @() }
        Write-RakazoJsonFile -Value $imageSet -Path (Join-Path $point "image-set.json")
        foreach ($name in @("rakazo.pgdump", "rakazo-appdata.tar.gz", ".env", "docker-compose.images.yml", "RECOVERY.txt")) { "fixture $name" | Set-Content -LiteralPath (Join-Path $point $name) }
        $manifest = [ordered]@{
            schemaVersion = 1; kind = "rakazo-personal-recovery-point"; project = "rakazo-personal"; createdAt = [DateTime]::UtcNow.ToString("o")
            source = [ordered]@{ commit = "fixture" }; imageSetId = "sha256-fixture"
            imageArchive = [ordered]@{ relativePath = "../../image-sets/sha256-fixture/rakazo-images.tar"; sha256 = Get-RakazoFileSha256 (Join-Path $imageDirectory "rakazo-images.tar") }
        }
        Write-RakazoJsonFile -Value $manifest -Path (Join-Path $point "recovery-point.json")
        Write-RakazoChecksums -Directory $point -RelativePaths @("rakazo.pgdump", "rakazo-appdata.tar.gz", ".env", "docker-compose.images.yml", "image-set.json", "recovery-point.json", "RECOVERY.txt")
        $verifier = Join-Path $PSScriptRoot "..\..\windows-personal\Test-RakazoPersonalRecoveryPoint.ps1"
        $verified = & $verifier -RecoveryPointDirectory $point -AsObject
        Assert-Equal "sha256-fixture" $verified.Manifest.imageSetId
        "tampered" | Set-Content -LiteralPath (Join-Path $point "rakazo-appdata.tar.gz")
        Assert-Throws { & $verifier -RecoveryPointDirectory $point -AsObject }
    }
}
finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "`n$script:Passed passed; $script:Failed failed."
if ($script:Failed -gt 0) { exit 1 }
