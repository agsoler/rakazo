[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
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

function Assert-Equal {
    param($Expected, $Actual, [string]$Message = "Values differ")
    if ($Expected -ne $Actual) { throw "$Message. Expected '$Expected', got '$Actual'." }
}

function Assert-True {
    param([Parameter(Mandatory)][bool]$Condition, [string]$Message = "Expected true")
    if (-not $Condition) { throw $Message }
}

function Assert-Throws {
    param([Parameter(Mandatory)][scriptblock]$Body, [string]$Message = "Expected an exception")
    try { & $Body } catch { return }
    throw $Message
}

function New-SourceEnvironment {
    return [ordered]@{
        POSTGRES_USER = "source-user"
        POSTGRES_PASSWORD = "source-password"
        POSTGRES_DB = "source-database"
        BETTER_AUTH_SECRET = "source-auth"
        ENCRYPTION_KEY = "source-encryption"
        SCREEN_PROXY_SECRET = "source-screen"
        SANDBOX_SUPERVISOR_TOKEN = "source-supervisor"
        BETTER_AUTH_URL = "http://source.example"
        WEB_ORIGIN = "http://source.example"
        API_URL = "http://source-api.example"
        RAKAZO_HOST = "source.example"
        SIGNUPS_ENABLED = "false"
        SIGNUP_ALLOWLIST = "owner@example.invalid"
        RAKAZO_IMAGE = "official/app"
        RAKAZO_IMAGE_TAG = "edge"
        RAKAZO_COMPUTER_IMAGE = "official/computer"
        RAKAZO_COMPUTER_IMAGE_TAG = "edge"
        SANDBOX_PROVIDER = "docker"
        OLLAMA_HOST = "http://source-model.example"
    }
}

function New-TargetEnvironment {
    return [ordered]@{
        POSTGRES_USER = "target-user"
        POSTGRES_PASSWORD = "target-password"
        POSTGRES_DB = "target-database"
        BETTER_AUTH_SECRET = "target-auth"
        ENCRYPTION_KEY = "target-encryption"
        SCREEN_PROXY_SECRET = "target-screen"
        SANDBOX_SUPERVISOR_TOKEN = "target-supervisor"
        BETTER_AUTH_URL = "http://127.0.0.1:5400"
        WEB_ORIGIN = "http://127.0.0.1:5400"
        API_URL = "http://127.0.0.1:3300"
        RAKAZO_HOST = "127.0.0.1"
        RAKAZO_WEB_PORT = "5400"
        RAKAZO_API_PORT = "3300"
        SIGNUPS_ENABLED = "true"
        SIGNUP_ALLOWLIST = ""
        RAKAZO_IMAGE = "rakazo-personal/app"
        RAKAZO_IMAGE_TAG = "sha-fixture"
        RAKAZO_COMPUTER_IMAGE = "rakazo-personal/computer"
        RAKAZO_COMPUTER_IMAGE_TAG = "sha-fixture"
        RAKAZO_DEPLOYMENT_ID = "rakazo-personal"
        SANDBOX_PROVIDER = "docker"
        RAKAZO_LOCAL_MODELS = "model-a,model-b"
        RAKAZO_LOCAL_MODELS_URL = "http://host.docker.internal:11434/v1"
        PI_DEFAULT_PROVIDER = "openai"
        PI_DEFAULT_MODEL = "model-a"
    }
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) "rakazo-migration-tests-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $testRoot | Out-Null

try {
    Invoke-Test "merge retains source data keys and target deployment keys" {
        $result = Merge-RakazoReleaseEnvironment -Source (New-SourceEnvironment) -Target (New-TargetEnvironment)
        Assert-Equal "source-password" $result.Values.POSTGRES_PASSWORD
        Assert-Equal "source-encryption" $result.Values.ENCRYPTION_KEY
        Assert-Equal "false" $result.Values.SIGNUPS_ENABLED
        Assert-Equal "http://127.0.0.1:5400" $result.Values.BETTER_AUTH_URL
        Assert-Equal "5400" $result.Values.RAKAZO_WEB_PORT
        Assert-Equal "rakazo-personal/app" $result.Values.RAKAZO_IMAGE
        Assert-Equal "model-a,model-b" $result.Values.RAKAZO_LOCAL_MODELS
        Assert-True (-not $result.Values.Contains("OLLAMA_HOST")) "Obsolete release model URL leaked into the target."
    }

    Invoke-Test "merge rejects an unclassified source setting without exposing values" {
        $source = New-SourceEnvironment
        $source.UNEXPECTED_SETTING = "private-value"
        $message = ""
        try { Merge-RakazoReleaseEnvironment -Source $source -Target (New-TargetEnvironment) | Out-Null }
        catch { $message = $_.Exception.Message }
        Assert-True ($message.Contains("UNEXPECTED_SETTING")) "The unknown key name was not reported."
        Assert-True (-not $message.Contains("private-value")) "The unknown value was exposed."
    }

    Invoke-Test "merge rejects a wrong target deployment" {
        $target = New-TargetEnvironment
        $target.RAKAZO_DEPLOYMENT_ID = "rakazo-dev"
        Assert-Throws { Merge-RakazoReleaseEnvironment -Source (New-SourceEnvironment) -Target $target }
    }

    Invoke-Test "source identity covers point files and linked image files" {
        $point = Join-Path $testRoot "point"
        $linked = Join-Path $testRoot "linked"
        New-Item -ItemType Directory -Path $point, $linked | Out-Null
        "state-one" | Set-Content -LiteralPath (Join-Path $point "state.bin")
        "image-one" | Set-Content -LiteralPath (Join-Path $linked "image.tar")
        $linkedPath = Join-Path $linked "image.tar"
        $first = Get-RakazoMigrationSourceIdentity -RecoveryPointDirectory $point -AdditionalFiles @($linkedPath)
        $second = Get-RakazoMigrationSourceIdentity -RecoveryPointDirectory $point -AdditionalFiles @($linkedPath)
        Assert-Equal $first $second
        "image-two" | Set-Content -LiteralPath $linkedPath
        $third = Get-RakazoMigrationSourceIdentity -RecoveryPointDirectory $point -AdditionalFiles @($linkedPath)
        Assert-True ($first -ne $third) "Linked image tampering did not change source identity."
    }

    Invoke-Test "image roles come from explicit environment references" {
        $roles = Get-RakazoMigrationImageRoles -Environment (New-SourceEnvironment)
        Assert-Equal "official/app:edge" $roles.App
        Assert-Equal "official/computer:edge" $roles.Computer
    }
}
finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "`n$script:Passed passed; $script:Failed failed."
if ($script:Failed -gt 0) { exit 1 }
