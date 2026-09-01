[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$modulePath = Join-Path $PSScriptRoot "..\Rakazo.Operations.psm1"
Import-Module $modulePath -Force
. (Join-Path $PSScriptRoot "..\..\windows-migration\RakazoMigration.Common.ps1")

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
        [string]$Deployment = "",
        [string]$Source,
        [string]$Destination = "/home/rakazo"
    )
    $labels = [ordered]@{
        'rakazo.managed' = $(if ($Managed) { "true" } else { "false" })
        'com.docker.compose.project' = $Project
    }
    if ($Deployment) { $labels.'rakazo.deployment' = $Deployment }
    return [pscustomobject]@{
        Config = [pscustomobject]@{ Labels = [pscustomobject]$labels }
        Mounts = @([pscustomobject]@{ Source = $Source; Destination = $Destination })
    }
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) "rakazo-operations-tests-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $testRoot | Out-Null

try {
    Invoke-Test "path containment accepts descendants but not the root or siblings" {
        $root = Join-Path $testRoot "root"
        New-Item -ItemType Directory -Force -Path $root | Out-Null
        Assert-True (Test-RakazoPathWithin -Path (Join-Path $root "child\file") -Root $root)
        Assert-False (Test-RakazoPathWithin -Path $root -Root $root)
        Assert-False (Test-RakazoPathWithin -Path (Join-Path $testRoot "root-other") -Root $root)
        Assert-Throws { Assert-RakazoSafeChildPath -Path (Join-Path $root "..\escape") -AllowedRoot $root }
        Assert-Throws { Resolve-RakazoContainedPath -BaseDirectory (Join-Path $root "child") -RelativePath "..\..\escape.tar" -AllowedRoot $root }
        if ($IsWindows) {
            $outside = Join-Path $testRoot "outside"
            New-Item -ItemType Directory -Path $outside | Out-Null
            $junction = Join-Path $root "junction"
            New-Item -ItemType Junction -Path $junction -Target $outside | Out-Null
            Assert-Throws { Assert-RakazoSafeChildPath -Path (Join-Path $junction "archive.tar") -AllowedRoot $root }
        }
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

    Invoke-Test "cross-deployment imports discard only ephemeral computer runtime state" {
        $sql = Get-RakazoMigrationComputerRuntimeResetSql
        foreach ($fragment in @(
            "DELETE FROM computer_execution_leases",
            "state = 'stopped'",
            '"providerRef" = NULL',
            '"screenUrl" = NULL',
            '"controlHolder" = ''none''',
            '"controlLeaseId" = NULL',
            '"executionRunId" = NULL',
            '"computerSwitching" = FALSE'
        )) {
            Assert-True ($sql.Contains($fragment)) "Missing runtime reset fragment: $fragment"
        }
        foreach ($durableColumn in @('"homeKey"', '"homeRevision"')) {
            Assert-False ($sql.Contains($durableColumn)) "Runtime reset must not alter $durableColumn"
        }
    }

    Invoke-Test "checksums pass intact files and reject tampering" {
        $directory = Join-Path $testRoot "checksums"
        New-Item -ItemType Directory -Path $directory | Out-Null
        "alpha" | Set-Content -LiteralPath (Join-Path $directory "a.txt")
        Write-RakazoChecksums -Directory $directory -RelativePaths @("a.txt")
        $verified = @(Test-RakazoChecksums -Directory $directory)
        Assert-Equal 1 $verified.Count
        Assert-Throws { Assert-RakazoRequiredChecksums -Directory $directory -RequiredPaths @("a.txt", "missing.txt") }
        "tampered" | Set-Content -LiteralPath (Join-Path $directory "a.txt")
        Assert-Throws { Test-RakazoChecksums -Directory $directory }
    }

    Invoke-Test "image-set IDs are stable and change with an image ID" {
        $images = @(
            [ordered]@{ reference = "example/app:sha-a"; id = "sha256:$('1' * 64)"; repoDigests = @(); architecture = "amd64"; os = "linux" },
            [ordered]@{ reference = "example/computer:sha-a"; id = "sha256:$('2' * 64)"; repoDigests = @(); architecture = "amd64"; os = "linux" }
        )
        $first = New-RakazoImageSetManifest -Images $images -SourceCommit ("a" * 40)
        $second = New-RakazoImageSetManifest -Images @($images[1], $images[0]) -SourceCommit ("a" * 40)
        Assert-Equal $first.imageSetId $second.imageSetId
        [void](Assert-RakazoImageSetManifest -Manifest ([pscustomobject]$first))
        $changed = @($images[0], [ordered]@{ reference = "example/computer:sha-a"; id = "sha256:$('3' * 64)"; repoDigests = @(); architecture = "amd64"; os = "linux" })
        $third = New-RakazoImageSetManifest -Images $changed -SourceCommit ("a" * 40)
        Assert-False ($first.imageSetId -eq $third.imageSetId) "Image-set ID did not change"
        $tampered = [pscustomobject]($first | ConvertTo-Json -Depth 10 | ConvertFrom-Json)
        $tampered.images[0].id = "sha256:$('4' * 64)"
        Assert-Throws { Assert-RakazoImageSetManifest -Manifest $tampered }
    }

    Invoke-Test "personal image activation accepts role-labelled official or custom tags" {
        $directory = Join-Path $testRoot "image-activation"
        New-Item -ItemType Directory -Path $directory | Out-Null
        $envPath = Join-Path $directory ".env"
        $currentPath = Join-Path $directory "current-image-set.json"
        Write-RakazoEnvFile -Values ([ordered]@{
            RAKAZO_IMAGE = "placeholder/app"; RAKAZO_IMAGE_TAG = "old"
            RAKAZO_COMPUTER_IMAGE = "placeholder/computer"; RAKAZO_COMPUTER_IMAGE_TAG = "old"
        }) -Path $envPath
        $images = @(
            [ordered]@{ reference = "registry.example/official/app:release-1"; id = "sha256:$('5' * 64)"; repoDigests = @(); architecture = "amd64"; os = "linux" },
            [ordered]@{ reference = "registry.example/official/computer:release-1"; id = "sha256:$('6' * 64)"; repoDigests = @(); architecture = "amd64"; os = "linux" }
        )
        $manifest = New-RakazoImageSetManifest -Images $images -SourceCommit "published-image"
        $manifest["roles"] = [ordered]@{ app = $images[0].reference; computer = $images[1].reference }
        $manifestPath = Join-Path $directory "official-image-set.json"
        Write-RakazoJsonFile -Value $manifest -Path $manifestPath
        $context = [pscustomobject]@{ Project = "rakazo-personal"; EnvFile = $envPath; CurrentImageSetFile = $currentPath }
        Set-RakazoPersonalImageSet -Context $context -ManifestPath $manifestPath
        $values = Read-RakazoEnvFile $envPath
        Assert-Equal "registry.example/official/app" $values.RAKAZO_IMAGE
        Assert-Equal "release-1" $values.RAKAZO_IMAGE_TAG
        Assert-Equal "registry.example/official/computer" $values.RAKAZO_COMPUTER_IMAGE
        Assert-Equal "release-1" $values.RAKAZO_COMPUTER_IMAGE_TAG
        Assert-Equal "rakazo-personal" $values.RAKAZO_DEPLOYMENT_ID
        Assert-Equal "rakazo-personal_data" $values.RAKAZO_COMPUTER_EXTRA_NETWORK
        [void](Assert-RakazoPersonalActiveImageSet -Context ([pscustomobject]@{
            Project = "rakazo-personal"; EnvFile = $envPath; CurrentImageSetFile = $currentPath; DockerContext = "fixture"
        }))
        $values.RAKAZO_IMAGE_TAG = "not-recorded"
        Write-RakazoEnvFile -Values $values -Path $envPath
        Assert-Throws { Assert-RakazoPersonalActiveImageSet -Context ([pscustomobject]@{
            Project = "rakazo-personal"; EnvFile = $envPath; CurrentImageSetFile = $currentPath; DockerContext = "fixture"
        }) }
    }

    Invoke-Test "bot ownership accepts only managed homes beneath the requested appdata root" {
        $root = "/var/lib/docker/volumes/rakazo-personal_appdata/_data"
        $owned = New-BotFixture -Managed $true -Project "" -Source "$root/homes/team-one"
        Assert-True (Test-RakazoBotOwnership -Container $owned -ExpectedAppDataRoot $root -ExpectedProject "rakazo-personal")
        $ownedWithProject = New-BotFixture -Managed $true -Project "rakazo-personal" -Source "$root/homes/team-two"
        Assert-True (Test-RakazoBotOwnership -Container $ownedWithProject -ExpectedAppDataRoot $root -ExpectedProject "rakazo-personal")
        $ownedWithDeployment = New-BotFixture -Managed $true -Project "" -Deployment "rakazo-personal" -Source "$root/homes/team-scoped"
        Assert-True (Test-RakazoBotOwnership -Container $ownedWithDeployment -ExpectedAppDataRoot $root -ExpectedProject "rakazo-personal")
        $ownedWithoutComposeLabel = [pscustomobject]@{
            Config = [pscustomobject]@{ Labels = [pscustomobject]@{
                'rakazo.managed' = 'true'
                'rakazo.deployment' = 'rakazo-personal'
            } }
            Mounts = @([pscustomobject]@{ Source = "$root/homes/team-no-compose-label"; Destination = "/home/rakazo" })
        }
        Assert-True (Test-RakazoBotOwnership -Container $ownedWithoutComposeLabel -ExpectedAppDataRoot $root -ExpectedProject "rakazo-personal")
        $wrongDeployment = New-BotFixture -Managed $true -Project "" -Deployment "rakazo-dev" -Source "$root/homes/team-other-scope"
        Assert-False (Test-RakazoBotOwnership -Container $wrongDeployment -ExpectedAppDataRoot $root -ExpectedProject "rakazo-personal")
        $wrongProject = New-BotFixture -Managed $true -Project "rakazo-dev" -Source "$root/homes/team-three"
        Assert-False (Test-RakazoBotOwnership -Container $wrongProject -ExpectedAppDataRoot $root -ExpectedProject "rakazo-personal")
        $wrongRoot = New-BotFixture -Managed $true -Project "" -Source "/var/lib/docker/volumes/rakazo_appdata/_data/homes/team-four"
        Assert-False (Test-RakazoBotOwnership -Container $wrongRoot -ExpectedAppDataRoot $root -ExpectedProject "rakazo-personal")
        $unmanaged = New-BotFixture -Managed $false -Project "" -Source "$root/homes/team-five"
        Assert-False (Test-RakazoBotOwnership -Container $unmanaged -ExpectedAppDataRoot $root -ExpectedProject "rakazo-personal")
        $wrongDestination = New-BotFixture -Managed $true -Project "" -Source "$root/homes/team-six" -Destination "/workspace"
        Assert-False (Test-RakazoBotOwnership -Container $wrongDestination -ExpectedAppDataRoot $root -ExpectedProject "rakazo-personal")
    }

    Invoke-Test "volume ownership requires exact Compose project and logical volume labels" {
        $owned = [pscustomobject]@{ Labels = [pscustomobject]@{ 'com.docker.compose.project' = 'rakazo'; 'com.docker.compose.volume' = 'appdata' } }
        Assert-True (Test-RakazoVolumeOwnership -Volume $owned -ExpectedProject "rakazo" -ExpectedVolume "appdata")
        Assert-False (Test-RakazoVolumeOwnership -Volume $owned -ExpectedProject "rakazo-dev" -ExpectedVolume "appdata")
        Assert-False (Test-RakazoVolumeOwnership -Volume $owned -ExpectedProject "rakazo" -ExpectedVolume "pgdata")
        Assert-False (Test-RakazoVolumeOwnership -Volume ([pscustomobject]@{ Labels = $null }) -ExpectedProject "rakazo" -ExpectedVolume "appdata")
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
        $images = @(
            [ordered]@{ reference = "example/app:sha-fixture"; id = "sha256:$('a' * 64)"; repoDigests = @(); architecture = "amd64"; os = "linux" },
            [ordered]@{ reference = "example/computer:sha-fixture"; id = "sha256:$('b' * 64)"; repoDigests = @(); architecture = "amd64"; os = "linux" }
        )
        $imageSet = New-RakazoImageSetManifest -Images $images -SourceCommit ("c" * 40)
        $imageDirectory = Join-Path $fixtureRoot "image-sets\$($imageSet.imageSetId)"
        New-Item -ItemType Directory -Force -Path $point, $imageDirectory | Out-Null
        $archivePath = Join-Path $imageDirectory "rakazo-images.tar"
        "fake image archive" | Set-Content -LiteralPath $archivePath
        Write-RakazoJsonFile -Value $imageSet -Path (Join-Path $imageDirectory "image-set.json")
        $archiveMetadata = [ordered]@{ schemaVersion = 1; kind = "rakazo-image-archive"; imageSetId = $imageSet.imageSetId; file = "rakazo-images.tar"; sha256 = Get-RakazoFileSha256 $archivePath; size = (Get-Item $archivePath).Length }
        Write-RakazoJsonFile -Value $archiveMetadata -Path (Join-Path $imageDirectory "archive.json")
        Write-RakazoChecksums -Directory $imageDirectory -RelativePaths @("image-set.json", "archive.json", "rakazo-images.tar")
        Write-RakazoJsonFile -Value $imageSet -Path (Join-Path $point "image-set.json")
        foreach ($name in @("rakazo.pgdump", "rakazo-appdata.tar.gz", "docker-compose.images.yml", "RECOVERY.txt")) { "fixture $name" | Set-Content -LiteralPath (Join-Path $point $name) }
        Write-RakazoEnvFile -Values ([ordered]@{ RAKAZO_IMAGE = "example/app"; RAKAZO_IMAGE_TAG = "sha-fixture"; RAKAZO_COMPUTER_IMAGE = "example/computer"; RAKAZO_COMPUTER_IMAGE_TAG = "sha-fixture" }) -Path (Join-Path $point ".env")
        $manifest = [ordered]@{
            schemaVersion = 1; kind = "rakazo-personal-recovery-point"; project = "rakazo-personal"; createdAt = [DateTime]::UtcNow.ToString("o")
            source = [ordered]@{ commit = "fixture" }; imageSetId = $imageSet.imageSetId
            imageArchive = [ordered]@{ relativePath = "../../image-sets/$($imageSet.imageSetId)/rakazo-images.tar"; sha256 = $archiveMetadata.sha256; size = $archiveMetadata.size }
        }
        Write-RakazoJsonFile -Value $manifest -Path (Join-Path $point "recovery-point.json")
        Write-RakazoChecksums -Directory $point -RelativePaths @("rakazo.pgdump", "rakazo-appdata.tar.gz", ".env", "docker-compose.images.yml", "image-set.json", "recovery-point.json", "RECOVERY.txt")
        $verifier = Join-Path $PSScriptRoot "..\..\windows-personal\Test-RakazoPersonalRecoveryPoint.ps1"
        $verified = & $verifier -RecoveryPointDirectory $point -AsObject
        Assert-Equal $imageSet.imageSetId $verified.Manifest.imageSetId

        $deployment = Join-Path $fixtureRoot "deployment"
        New-Item -ItemType Directory -Path $deployment | Out-Null
        Copy-Item -LiteralPath (Join-Path $point ".env") -Destination (Join-Path $deployment ".env")
        Copy-Item -LiteralPath (Join-Path $point "docker-compose.images.yml") -Destination (Join-Path $deployment "docker-compose.images.yml")
        Write-RakazoJsonFile -Value ([ordered]@{
            schemaVersion = 1; kind = "rakazo-personal-config"; project = "rakazo-personal"
            deploymentRoot = $deployment; recoveryRoot = $fixtureRoot
            nas = [ordered]@{ repository = ""; passwordFile = "" }
        }) -Path (Join-Path $deployment "personal-config.json")
        $sync = Join-Path $PSScriptRoot "..\..\windows-personal\Sync-RakazoPersonalBackups.ps1"
        Assert-Throws { & $sync -DeploymentRoot $deployment -RecoveryRoot $fixtureRoot }
        $replication = Get-Content -Raw -LiteralPath (Join-Path $deployment "replication-state.json") | ConvertFrom-Json
        Assert-Equal "pending" $replication.status
        Assert-Equal 1 @($replication.recoveryPoints).Count

        $resticRepository = Join-Path $fixtureRoot "fake-restic-repository"
        New-Item -ItemType Directory -Path $resticRepository | Out-Null
        $passwordFile = Join-Path $fixtureRoot "restic-password.txt"
        "fixture-password" | Set-Content -LiteralPath $passwordFile
        $configPath = Join-Path $deployment "personal-config.json"
        $personalConfig = Get-Content -Raw -LiteralPath $configPath | ConvertFrom-Json
        $personalConfig.nas.repository = $resticRepository
        $personalConfig.nas.passwordFile = $passwordFile
        Write-RakazoJsonFile -Value $personalConfig -Path $configPath
        $fakeRestic = Join-Path $fixtureRoot "restic-fixture.cmd"
        @(
            '@echo off',
            'if "%1"=="snapshots" echo []',
            'if "%1"=="cat" echo {"id":"fixture-repository-one"}',
            'if "%1"=="backup" echo {"message_type":"summary","snapshot_id":"fixture-snapshot"}',
            'exit /b 0'
        ) | Set-Content -LiteralPath $fakeRestic -Encoding ascii
        & $sync -DeploymentRoot $deployment -RecoveryRoot $fixtureRoot -ResticCommand $fakeRestic
        $replication = Get-Content -Raw -LiteralPath (Join-Path $deployment "replication-state.json") | ConvertFrom-Json
        Assert-Equal "synced" $replication.status
        Assert-Equal "synced" $replication.recoveryPoints[0].status
        Assert-Equal "fixture-snapshot" $replication.recoveryPoints[0].snapshotId

        $pointTwo = Join-Path $fixtureRoot "recovery-points\point-two"
        Copy-Item -LiteralPath $point -Destination $pointTwo -Recurse
        @('@echo off', 'if "%1"=="snapshots" echo []', 'if "%1"=="cat" echo {"id":"fixture-repository-one"}', 'if "%1"=="backup" exit /b 9', 'exit /b 0') |
            Set-Content -LiteralPath $fakeRestic -Encoding ascii
        Assert-Throws { & $sync -DeploymentRoot $deployment -RecoveryRoot $fixtureRoot -ResticCommand $fakeRestic }
        $replication = Get-Content -Raw -LiteralPath (Join-Path $deployment "replication-state.json") | ConvertFrom-Json
        Assert-Equal "synced" (@($replication.recoveryPoints | Where-Object recoveryPointId -eq "point-one")[0].status)
        Assert-Equal "pending" (@($replication.recoveryPoints | Where-Object recoveryPointId -eq "point-two")[0].status)

        @('@echo off', 'if "%1"=="snapshots" echo []', 'if "%1"=="cat" echo {"id":"fixture-repository-two"}', 'if "%1"=="backup" exit /b 9', 'exit /b 0') |
            Set-Content -LiteralPath $fakeRestic -Encoding ascii
        Assert-Throws { & $sync -DeploymentRoot $deployment -RecoveryRoot $fixtureRoot -ResticCommand $fakeRestic }
        $replication = Get-Content -Raw -LiteralPath (Join-Path $deployment "replication-state.json") | ConvertFrom-Json
        Assert-Equal "pending" $replication.status
        Assert-True (@($replication.recoveryPoints | Where-Object status -ne "pending").Count -eq 0) "A new repository retained stale synced records"

        $retrievalDeployment = Join-Path $testRoot "retrieval-deployment"
        $localCatalogue = Join-Path $testRoot "retrieved-local-catalogue"
        New-Item -ItemType Directory -Path $retrievalDeployment | Out-Null
        Copy-Item -LiteralPath (Join-Path $point ".env") -Destination (Join-Path $retrievalDeployment ".env")
        Copy-Item -LiteralPath (Join-Path $point "docker-compose.images.yml") -Destination (Join-Path $retrievalDeployment "docker-compose.images.yml")
        Write-RakazoJsonFile -Value ([ordered]@{
            schemaVersion = 1; kind = "rakazo-personal-config"; project = "rakazo-personal"
            deploymentRoot = $retrievalDeployment; recoveryRoot = $localCatalogue
            nas = [ordered]@{ repository = $resticRepository; passwordFile = $passwordFile }
        }) -Path (Join-Path $retrievalDeployment "personal-config.json")
        $retrievalDestination = Join-Path $testRoot "restic-retrieval-output"
        $recoveredRoot = Join-Path $retrievalDestination (Split-Path -Leaf $localCatalogue)
        $fakeRestore = Join-Path $testRoot "restic-restore-fixture.cmd"
        @(
            '@echo off',
            "robocopy `"$fixtureRoot`" `"$recoveredRoot`" /E >nul",
            'if errorlevel 8 exit /b 8',
            'exit /b 0'
        ) | Set-Content -LiteralPath $fakeRestore -Encoding ascii
        $retrieve = Join-Path $PSScriptRoot "..\..\windows-personal\Get-RakazoPersonalRecoveryPoint.ps1"
        & $retrieve -SnapshotId "fixture-snapshot" -DestinationDirectory $retrievalDestination -DeploymentRoot $retrievalDeployment -RecoveryRoot $localCatalogue -ResticCommand $fakeRestore
        Assert-True (Test-Path -LiteralPath (Join-Path $localCatalogue "recovery-points\point-one\recovery-point.json"))
        Assert-True (Test-Path -LiteralPath (Join-Path $localCatalogue "image-sets\$($imageSet.imageSetId)\rakazo-images.tar"))

        $localImageDirectory = Join-Path $localCatalogue "image-sets\$($imageSet.imageSetId)"
        $localArchive = Join-Path $localImageDirectory "rakazo-images.tar"
        "different valid archive encoding" | Set-Content -LiteralPath $localArchive
        $differentArchiveMetadata = [ordered]@{
            schemaVersion = 1; kind = "rakazo-image-archive"; imageSetId = $imageSet.imageSetId
            file = "rakazo-images.tar"; sha256 = Get-RakazoFileSha256 $localArchive; size = (Get-Item $localArchive).Length
        }
        Write-RakazoJsonFile -Value $differentArchiveMetadata -Path (Join-Path $localImageDirectory "archive.json")
        Write-RakazoChecksums -Directory $localImageDirectory -RelativePaths @("image-set.json", "archive.json", "rakazo-images.tar")
        Remove-Item -LiteralPath (Join-Path $localCatalogue "recovery-points\point-one") -Recurse -Force
        Remove-Item -LiteralPath (Join-Path $localCatalogue "recovery-points\point-two") -Recurse -Force
        $conflictDestination = Join-Path $testRoot "restic-conflict-output"
        $conflictRoot = Join-Path $conflictDestination (Split-Path -Leaf $localCatalogue)
        @(
            '@echo off',
            "robocopy `"$fixtureRoot`" `"$conflictRoot`" /E >nul",
            'if errorlevel 8 exit /b 8',
            'exit /b 0'
        ) | Set-Content -LiteralPath $fakeRestore -Encoding ascii
        Assert-Throws { & $retrieve -SnapshotId "fixture-snapshot" -DestinationDirectory $conflictDestination -DeploymentRoot $retrievalDeployment -RecoveryRoot $localCatalogue -ResticCommand $fakeRestore }
        Assert-False (Test-Path -LiteralPath (Join-Path $localCatalogue "recovery-points\point-one")) "Conflicting point was published before verification"
        Assert-True (Test-Path -LiteralPath (Join-Path $localCatalogue "recovery-points\.point-one.incomplete")) "Failed import evidence was not retained"

        $safeRelativePath = $manifest.imageArchive.relativePath
        $manifest.imageArchive.relativePath = "../../../outside.tar"
        Write-RakazoJsonFile -Value $manifest -Path (Join-Path $point "recovery-point.json")
        Write-RakazoChecksums -Directory $point -RelativePaths @("rakazo.pgdump", "rakazo-appdata.tar.gz", ".env", "docker-compose.images.yml", "image-set.json", "recovery-point.json", "RECOVERY.txt")
        Assert-Throws { & $verifier -RecoveryPointDirectory $point -AsObject }
        $manifest.imageArchive.relativePath = $safeRelativePath
        Write-RakazoJsonFile -Value $manifest -Path (Join-Path $point "recovery-point.json")
        Write-RakazoChecksums -Directory $point -RelativePaths @("rakazo.pgdump", "rakazo-appdata.tar.gz", ".env", "docker-compose.images.yml", "image-set.json", "recovery-point.json", "RECOVERY.txt")

        "tampered" | Set-Content -LiteralPath (Join-Path $point "rakazo-appdata.tar.gz")
        Assert-Throws { & $verifier -RecoveryPointDirectory $point -AsObject }
    }
}
finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "`n$script:Passed passed; $script:Failed failed."
if ($script:Failed -gt 0) { exit 1 }
